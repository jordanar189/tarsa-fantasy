// Mirrors nflverse snap_counts CSV into snap_counts.
//
// Body (all optional):
//   { "seasons": [2023, 2024, 2025] }
//   { "from": 2020 }
//   {}                  // default: current season + previous
//
// Source: snap_counts_{YEAR}.csv from the snap_counts release. Only the
// offensive side is stored — defensive/ST snaps aren't useful for fantasy.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const URL_TEMPLATE     = "https://github.com/nflverse/nflverse-data/releases/download/snap_counts/snap_counts_{YEAR}.csv";

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

interface SnapRow {
    player_id: string; season: number; week: number;
    team: string;
    offense_snaps: number; offense_pct: number;
}

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const seasons = pickSeasons(body);
        const out: Record<number, unknown> = {};
        for (const y of seasons) out[y] = await syncSeason(y);
        return new Response(JSON.stringify({ ok: true, seasons: out }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function pickSeasons(body: { seasons?: number[]; from?: number }): number[] {
    const now = new Date();
    const currentSeason = now.getUTCMonth() >= 8
        ? now.getUTCFullYear()
        : now.getUTCFullYear() - 1;
    if (body.seasons?.length) return body.seasons;
    if (body.from != null) {
        const arr: number[] = [];
        for (let y = body.from; y <= currentSeason; y++) arr.push(y);
        return arr;
    }
    return [currentSeason - 1, currentSeason];
}

async function syncSeason(year: number): Promise<unknown> {
    const url = URL_TEMPLATE.replace("{YEAR}", String(year));
    const resp = await fetch(url);
    if (resp.status === 404) return { skipped: "not_published_yet" };
    if (!resp.ok) return { error: `HTTP ${resp.status}` };
    const csv = await resp.text();
    const rows = parseRows(csv, year);
    if (rows.length === 0) return { rows: 0 };
    const chunk = 1000;
    for (let i = 0; i < rows.length; i += chunk) {
        const slice = rows.slice(i, i + chunk);
        const { error } = await supa.from("snap_counts")
            .upsert(slice, { onConflict: "player_id,season,week" });
        if (error) throw new Error(error.message);
    }
    return { rows: rows.length };
}

function parseRows(csv: string, year: number): SnapRow[] {
    const rows = parseCsv(csv);
    const header = rows.shift();
    if (!header) return [];
    const ix = {
        pid:      header.indexOf("pfr_player_id") >= 0 ? header.indexOf("pfr_player_id") : header.indexOf("gsis_id"),
        gsis:     header.indexOf("gsis_id"),
        season:   header.indexOf("season"),
        week:     header.indexOf("week"),
        team:     header.indexOf("team"),
        offSnaps: header.indexOf("offense_snaps"),
        offPct:   header.indexOf("offense_pct"),
    };
    // We strictly need a player ID we can join to players_cache (gsis_id).
    if (ix.gsis < 0 || ix.offSnaps < 0) return [];
    const out: SnapRow[] = [];
    for (const r of rows) {
        const pid = r[ix.gsis]?.trim();
        if (!pid || pid.toUpperCase() === "NA") continue;
        const snaps = numOrNull(r[ix.offSnaps]);
        if (snaps == null || snaps <= 0) continue;
        const pct = numOrNull(r[ix.offPct]) ?? 0;
        out.push({
            player_id: pid,
            season: ix.season >= 0 ? Math.trunc(Number(r[ix.season])) : year,
            week:   ix.week   >= 0 ? Math.trunc(Number(r[ix.week]))   : 0,
            team:   (ix.team  >= 0 ? r[ix.team] : "")?.trim() ?? "",
            offense_snaps: Math.trunc(snaps),
            // Some CSVs store pct as 0-1, others 0-100. Normalize to 0-100.
            offense_pct: pct <= 1.0 ? round2(pct * 100) : round2(pct),
        });
    }
    return out;
}

function numOrNull(v: string | undefined): number | null {
    if (!v) return null;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return null;
    const n = Number(s);
    return Number.isFinite(n) ? n : null;
}

function round2(x: number): number { return Math.round(x * 100) / 100; }

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
