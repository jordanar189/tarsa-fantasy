// Mirrors nflverse weekly player stats into Supabase. Runs daily via pg_cron.
//
// Body (all optional):
//   { "seasons": [2023, 2024, 2025] }       // explicit list
//   { "from": 2023 }                         // from this year through current
//   {}                                       // default: current year + previous
//
// Reads stats_player_week_{year}.csv from the new "stats_player" release tag
// (nflverse renamed from "player_stats" in 2025). Also pulls rosters_{year}.csv
// to populate espn_id for ESPN live-score cross-referencing.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL          = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STATS_URL_TEMPLATE    = "https://github.com/nflverse/nflverse-data/releases/download/stats_player/stats_player_week_{YEAR}.csv";
const ROSTERS_URL_TEMPLATE  = "https://github.com/nflverse/nflverse-data/releases/download/rosters/roster_{YEAR}.csv";

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

interface PlayerRow {
    id: string; espn_id: string | null; name: string;
    position: string; position_group: string;
    team: string; headshot_url: string;
    // Bio columns added in the Phase 1 stats overhaul. All nullable —
    // upserts only set them when the rosters CSV provided a value.
    birth_date?: string | null;
    height_in?: number | null;
    weight_lb?: number | null;
    college?: string | null;
    jersey_number?: number | null;
    draft_year?: number | null;
    draft_round?: number | null;
    draft_pick?: number | null;
    years_exp?: number | null;
    status?: string | null;
}
interface GameRow {
    player_id: string; season: number; week: number;
    team: string; opponent: string;
    completions: number; attempts: number;
    passing_yards: number; passing_tds: number; passing_interceptions: number;
    carries: number; rushing_yards: number; rushing_tds: number;
    receptions: number; targets: number;
    receiving_yards: number; receiving_tds: number;
    fumbles_lost: number;
    fantasy_points: number; fantasy_points_ppr: number; fantasy_points_half_ppr: number;
}

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const seasons = pickSeasons(body);
        const results: Record<number, unknown> = {};
        for (const year of seasons) {
            results[year] = await syncSeason(year);
        }
        return new Response(JSON.stringify({ ok: true, seasons: results }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        console.error(err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function pickSeasons(body: { seasons?: number[]; from?: number }): number[] {
    const now = new Date();
    // NFL "season year" is the calendar year of Week 1. Week 1 is early Sep,
    // so before that, the latest finished season is last year.
    const currentSeason = now.getUTCMonth() >= 8 // Sep+
        ? now.getUTCFullYear()
        : now.getUTCFullYear() - 1;
    if (body.seasons?.length) return body.seasons;
    if (body.from != null) {
        const out: number[] = [];
        for (let y = body.from; y <= currentSeason; y++) out.push(y);
        return out;
    }
    // Default: current season + the one before it (re-sync recent in case of corrections)
    return [currentSeason - 1, currentSeason];
}

async function syncSeason(year: number): Promise<unknown> {
    const url = STATS_URL_TEMPLATE.replace("{YEAR}", String(year));
    const resp = await fetch(url);
    if (resp.status === 404) {
        return { skipped: "not_published_yet" };
    }
    if (!resp.ok) {
        return { error: `stats HTTP ${resp.status}` };
    }
    const csv = await resp.text();
    const { players, games } = parseStatsCsv(csv);
    if (players.size === 0) return { error: "empty parse" };

    // Augment with rosters data: ESPN IDs (for live-score xref) + bio columns.
    // Optional — sync still works if the rosters CSV 404s.
    const rosterByGsis = await fetchRosterMap(year);
    for (const [pid, r] of rosterByGsis) {
        const p = players.get(pid);
        if (!p) continue;
        if (r.espn_id) p.espn_id = r.espn_id;
        p.birth_date    = r.birth_date    ?? null;
        p.height_in     = r.height_in     ?? null;
        p.weight_lb     = r.weight_lb     ?? null;
        p.college       = r.college       ?? null;
        p.jersey_number = r.jersey_number ?? null;
        p.draft_year    = r.draft_year    ?? null;
        p.draft_round   = r.draft_round   ?? null;
        p.draft_pick    = r.draft_pick    ?? null;
        p.years_exp     = r.years_exp     ?? null;
        p.status        = r.status        ?? null;
    }

    // Upsert in chunks to stay within PostgREST payload limits.
    const playerRows = [...players.values()];
    const gameRows   = games;

    await upsertChunks("players_cache", playerRows, 500, "id");
    await upsertChunks("player_games",  gameRows,  500, "player_id,season,week");

    await supa.from("seasons").upsert({
        season: year,
        games_count: gameRows.length,
        last_synced_at: new Date().toISOString()
    });

    return { players: playerRows.length, games: gameRows.length };
}

interface RosterFields {
    espn_id?: string;
    birth_date?: string;
    height_in?: number;
    weight_lb?: number;
    college?: string;
    jersey_number?: number;
    draft_year?: number;
    draft_round?: number;
    draft_pick?: number;
    years_exp?: number;
    status?: string;
}

async function fetchRosterMap(year: number): Promise<Map<string, RosterFields>> {
    const url = ROSTERS_URL_TEMPLATE.replace("{YEAR}", String(year));
    const resp = await fetch(url);
    if (!resp.ok) return new Map();
    const csv = await resp.text();
    const rows = parseCsv(csv);
    const header = rows.shift();
    if (!header) return new Map();
    const ix = {
        gsis:       header.indexOf("gsis_id"),
        espn:       header.indexOf("espn_id"),
        birth:      header.indexOf("birth_date"),
        height:     header.indexOf("height"),
        weight:     header.indexOf("weight"),
        college:    header.indexOf("college"),
        jersey:     header.indexOf("jersey_number"),
        draftYear:  header.indexOf("rookie_year") >= 0 ? header.indexOf("rookie_year") : header.indexOf("entry_year"),
        draftRound: header.indexOf("draft_round"),   // -1 if missing; we'll compute
        draftPick:  header.indexOf("draft_number"),
        yearsExp:   header.indexOf("years_exp"),
        status:     header.indexOf("status"),
    };
    if (ix.gsis < 0) return new Map();
    const out = new Map<string, RosterFields>();
    for (const r of rows) {
        const gsis = r[ix.gsis]?.trim();
        if (!gsis) continue;
        const fields: RosterFields = {};
        const espn = ix.espn >= 0 ? r[ix.espn]?.trim() : "";
        if (espn && espn !== "NA") fields.espn_id = espn;

        const birth = ix.birth >= 0 ? r[ix.birth]?.trim() : "";
        if (birth && birth !== "NA") fields.birth_date = birth;
        const height = ix.height >= 0 ? numOrNull(r[ix.height]) : null;
        if (height != null) fields.height_in = Math.round(height);
        const weight = ix.weight >= 0 ? numOrNull(r[ix.weight]) : null;
        if (weight != null) fields.weight_lb = Math.round(weight);
        const college = ix.college >= 0 ? r[ix.college]?.trim() : "";
        if (college && college !== "NA") fields.college = college;
        const jersey = ix.jersey >= 0 ? numOrNull(r[ix.jersey]) : null;
        if (jersey != null) fields.jersey_number = Math.round(jersey);
        const dy = ix.draftYear >= 0 ? numOrNull(r[ix.draftYear]) : null;
        if (dy != null && dy > 0) fields.draft_year = Math.round(dy);
        // Pick: 0 / NA in nflverse means undrafted — store null, not 0.
        const dpRaw = ix.draftPick >= 0 ? numOrNull(r[ix.draftPick]) : null;
        const dp = dpRaw != null && dpRaw > 0 ? Math.round(dpRaw) : null;
        if (dp != null) fields.draft_pick = dp;
        // Round: prefer the CSV column when present, otherwise derive from
        // the overall pick. NFL rounds aren't exactly 32 picks (compensatory
        // picks shift things) but (pick - 1) / 32 + 1 puts everyone in the
        // right round through pick 224; beyond that the seventh round is
        // approximated. Good enough for a display label.
        const drRaw = ix.draftRound >= 0 ? numOrNull(r[ix.draftRound]) : null;
        const dr = drRaw != null && drRaw > 0
            ? Math.round(drRaw)
            : (dp != null ? Math.min(7, Math.floor((dp - 1) / 32) + 1) : null);
        if (dr != null) fields.draft_round = dr;
        const ye = ix.yearsExp >= 0 ? numOrNull(r[ix.yearsExp]) : null;
        if (ye != null) fields.years_exp = Math.round(ye);
        const status = ix.status >= 0 ? r[ix.status]?.trim() : "";
        if (status && status !== "NA") fields.status = status;

        out.set(gsis, fields);
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

async function upsertChunks<T>(table: string, rows: T[], chunk: number, onConflict: string) {
    for (let i = 0; i < rows.length; i += chunk) {
        const slice = rows.slice(i, i + chunk);
        const { error } = await supa.from(table).upsert(slice, { onConflict });
        if (error) throw new Error(`upsert ${table}[${i}..${i+slice.length}]: ${error.message}`);
    }
}

function parseStatsCsv(csv: string): { players: Map<string, PlayerRow>; games: GameRow[] } {
    const rows = parseCsv(csv);
    const header = rows.shift();
    if (!header) return { players: new Map(), games: [] };
    const col = (k: string) => header.indexOf(k);
    const ix = {
        season: col("season"), week: col("week"),
        season_type: col("season_type"),
        pid: col("player_id"),
        display: col("player_display_name"), name: col("player_name"),
        position: col("position"), position_group: col("position_group"),
        headshot: col("headshot_url"),
        team: col("team"), opp: col("opponent_team"),
        completions: col("completions"), attempts: col("attempts"),
        passYds: col("passing_yards"), passTds: col("passing_tds"), passInt: col("passing_interceptions"),
        carries: col("carries"), rushYds: col("rushing_yards"), rushTds: col("rushing_tds"),
        rec: col("receptions"), targets: col("targets"),
        recYds: col("receiving_yards"), recTds: col("receiving_tds"),
        fumSack: col("sack_fumbles_lost"), fumRush: col("rushing_fumbles_lost"), fumRec: col("receiving_fumbles_lost"),
        fp: col("fantasy_points"), fpPpr: col("fantasy_points_ppr")
    };

    const players = new Map<string, PlayerRow>();
    const games: GameRow[] = [];
    for (const r of rows) {
        if (ix.season_type >= 0 && (r[ix.season_type] ?? "").toUpperCase() !== "REG") continue;
        const pid = r[ix.pid]?.trim();
        if (!pid) continue;

        if (!players.has(pid)) {
            players.set(pid, {
                id: pid,
                espn_id: null,
                name: r[ix.display] ?? r[ix.name] ?? pid,
                position: r[ix.position] ?? "",
                position_group: r[ix.position_group] ?? "",
                team: r[ix.team] ?? "",
                headshot_url: r[ix.headshot] ?? ""
            });
        } else {
            const p = players.get(pid)!;
            if (r[ix.team]) p.team = r[ix.team]!;
        }

        const recs = num(r[ix.rec]);
        const fp = num(r[ix.fp]);
        games.push({
            player_id: pid,
            season: Math.trunc(num(r[ix.season])),
            week: Math.trunc(num(r[ix.week])),
            team: r[ix.team] ?? "",
            opponent: r[ix.opp] ?? "",
            completions: num(r[ix.completions]),
            attempts: num(r[ix.attempts]),
            passing_yards: num(r[ix.passYds]),
            passing_tds: num(r[ix.passTds]),
            passing_interceptions: num(r[ix.passInt]),
            carries: num(r[ix.carries]),
            rushing_yards: num(r[ix.rushYds]),
            rushing_tds: num(r[ix.rushTds]),
            receptions: recs,
            targets: num(r[ix.targets]),
            receiving_yards: num(r[ix.recYds]),
            receiving_tds: num(r[ix.recTds]),
            fumbles_lost: num(r[ix.fumSack]) + num(r[ix.fumRush]) + num(r[ix.fumRec]),
            fantasy_points: fp,
            fantasy_points_ppr: num(r[ix.fpPpr]),
            fantasy_points_half_ppr: round2(fp + 0.5 * recs)
        });
    }
    return { players, games };
}

function num(v: string | undefined): number {
    if (!v) return 0;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return 0;
    const n = Number(s);
    return Number.isFinite(n) ? n : 0;
}

function round2(x: number): number {
    return Math.round(x * 100) / 100;
}

// RFC 4180 CSV parser — handles quoted fields w/ embedded commas + newlines
// and "" for an escaped quote inside a quoted field.
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
            else if (c === "\r") { /* skip — handled by \n */ }
            else if (c === "\n") { row.push(field); field = ""; out.push(row); row = []; }
            else field += c;
        }
    }
    if (field.length > 0 || row.length > 0) { row.push(field); out.push(row); }
    return out;
}
