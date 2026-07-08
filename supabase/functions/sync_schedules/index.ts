// Mirrors the nflverse master schedules CSV into nfl_schedules.
// One row per NFL game ever played + scheduled. Includes final scores once
// games are completed. Status is derived from the score columns:
//   • result populated  → 'final'
//   • kickoff in the past, no result → 'in_progress' (best-effort)
//   • kickoff in the future          → 'scheduled'
// Rows are MERGED against what's already in the table before upserting
// (kickoff.ts): sync_schedules_espn's exact UTC kickoffs and finals written
// overnight by sync_espn_live survive; nflverse only overrides them on a
// real reschedule or with an actual result.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { ScheduleRow, ExistingRow, combineKickoff, mergeExisting } from "./kickoff.ts";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SCHEDULES_URL    = "https://github.com/nflverse/nflverse-data/releases/download/schedules/games.csv";

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

Deno.serve(async (_req: Request) => {
    try {
        const resp = await fetch(SCHEDULES_URL);
        if (!resp.ok) {
            return new Response(JSON.stringify({ error: `HTTP ${resp.status}` }), {
                status: 500, headers: { "Content-Type": "application/json" }
            });
        }
        const csv = await resp.text();
        const rows = parseRows(csv);
        const existing = await loadExisting();
        for (const row of rows) mergeExisting(row, existing.get(row.game_id));
        // Upsert in chunks to stay under PostgREST payload limits.
        const chunk = 500;
        for (let i = 0; i < rows.length; i += chunk) {
            const slice = rows.slice(i, i + chunk);
            const { error } = await supa.from("nfl_schedules")
                .upsert(slice, { onConflict: "game_id" });
            if (error) throw new Error(error.message);
        }
        return new Response(JSON.stringify({ ok: true, rows: rows.length }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function parseRows(csv: string): ScheduleRow[] {
    const rows = parseCsv(csv);
    const header = rows.shift();
    if (!header) return [];
    const ix = {
        gameID:    header.indexOf("game_id"),
        season:    header.indexOf("season"),
        week:      header.indexOf("week"),
        seasonType: header.indexOf("season_type"),
        home:      header.indexOf("home_team"),
        away:      header.indexOf("away_team"),
        gameday:   header.indexOf("gameday"),
        gametime:  header.indexOf("gametime"),
        homeScore: header.indexOf("home_score"),
        awayScore: header.indexOf("away_score"),
        result:    header.indexOf("result"),
    };
    if (ix.gameID < 0 || ix.season < 0 || ix.week < 0) return [];
    const out: ScheduleRow[] = [];
    const now = Date.now();
    for (const r of rows) {
        const gameID = r[ix.gameID]?.trim();
        if (!gameID) continue;
        // Skip non-regular-season rows for now to keep the table lean.
        const st = ix.seasonType >= 0 ? (r[ix.seasonType] ?? "").toUpperCase() : "REG";
        if (st !== "REG" && st !== "POST") continue;

        const homeScore = ix.homeScore >= 0 ? numOrNull(r[ix.homeScore]) : null;
        const awayScore = ix.awayScore >= 0 ? numOrNull(r[ix.awayScore]) : null;
        const result    = ix.result    >= 0 ? r[ix.result]?.trim()       : "";

        const kickoff = combineKickoff(r[ix.gameday], ix.gametime >= 0 ? r[ix.gametime] : "");
        let status = "scheduled";
        if (homeScore != null && awayScore != null && (result || "").length > 0) {
            status = "final";
        } else if (kickoff && new Date(kickoff).getTime() < now) {
            status = "in_progress";
        }
        out.push({
            game_id: gameID,
            season:  Math.trunc(Number(r[ix.season])),
            week:    Math.trunc(Number(r[ix.week])),
            home_team: (r[ix.home] ?? "").trim(),
            away_team: (r[ix.away] ?? "").trim(),
            kickoff,
            home_score: homeScore,
            away_score: awayScore,
            status,
        });
    }
    return out;
}

// Existing schedule rows, keyed by game_id. Other writers put better data in
// this table than the nflverse CSV carries — sync_schedules_espn writes exact
// UTC kickoffs, and sync_espn_live marks games final overnight before the CSV
// has ingested the result — so a blind upsert must not clobber them (merge
// rules live in kickoff.ts).
async function loadExisting(): Promise<Map<string, ExistingRow>> {
    const map = new Map<string, ExistingRow>();
    const page = 1000;
    for (let from = 0; ; from += page) {
        const { data, error } = await supa.from("nfl_schedules")
            .select("game_id, kickoff, status, home_score, away_score")
            .order("game_id")
            .range(from, from + page - 1);
        if (error) throw new Error(`load existing: ${error.message}`);
        for (const r of (data ?? []) as ExistingRow[]) map.set(r.game_id, r);
        if (!data || data.length < page) break;
    }
    return map;
}

function numOrNull(v: string | undefined): number | null {
    if (!v) return null;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return null;
    const n = Number(s);
    return Number.isFinite(n) ? n : null;
}

// RFC 4180 CSV parser, same as sync_nflverse.
function parseCsv(text: string): string[][] {
    const out: string[][] = [];
    let field = "", row: string[] = [], inQ = false;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (inQ) {
            if (c === "\"") {
                if (text[i + 1] === "\"") { field += "\""; i++; }
                else { inQ = false; }
            } else { field += c; }
        } else {
            if (c === "\"") inQ = true;
            else if (c === ",") { row.push(field); field = ""; }
            else if (c === "\r") { /* skip */ }
            else if (c === "\n") { row.push(field); field = ""; out.push(row); row = []; }
            else field += c;
        }
    }
    if (field.length > 0 || row.length > 0) { row.push(field); out.push(row); }
    return out;
}
