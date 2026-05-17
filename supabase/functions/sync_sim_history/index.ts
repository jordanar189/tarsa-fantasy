// Backfill historical data the Simulation feature needs to recreate the
// information environment of past seasons:
//   • injury_history       — from nflverse injuries_{year}.csv
//   • depth_charts         — from nflverse depth_charts_{year}.csv
//   • inactives            — derived from nflverse weekly_rosters where
//                            status indicates IR / suspended / inactive
//   • nfl_team_ranks_history — from team_ranks_at_week() per week
//   • nfl_schedules.total/weather/roof — from nflverse schedules_{year}.csv
//
// Trending history and most-started history are NOT backfilled here — those
// don't exist in nflverse. The sync_mfl cron writes the current week's
// trending into trending_history (live forward-only); past weeks of past
// seasons remain empty by design (use trending_proxy() in queries to fall
// back to a synthetic ranking).
//
// Body (all optional):
//   { "seasons": [2018, 2019, ...] }   // defaults to [currentSeason - 1, currentSeason]
//   { "feeds":   ["injuries","depth","inactives","schedules","ranks"] }
//
// Each feed is idempotent — re-running overwrites existing rows for the
// (season, week, player) keys it produces.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const INJ_URL  = "https://github.com/nflverse/nflverse-data/releases/download/injuries/injuries_{YEAR}.csv";
const DEPTH_URL = "https://github.com/nflverse/nflverse-data/releases/download/depth_charts/depth_charts_{YEAR}.csv";
const WROST_URL = "https://github.com/nflverse/nflverse-data/releases/download/weekly_rosters/roster_weekly_{YEAR}.csv";
const SCHED_URL = "https://github.com/nflverse/nflverse-data/releases/download/schedules/sched_{YEAR}.csv";

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const seasons = pickSeasons(body);
        const feeds: string[] = Array.isArray(body.feeds) ? body.feeds
            : ["injuries", "depth", "inactives", "schedules", "ranks"];

        const out: Record<string, unknown> = {};
        for (const year of seasons) {
            const r: Record<string, unknown> = {};
            if (feeds.includes("injuries"))  r.injuries  = await syncInjuries(year);
            if (feeds.includes("depth"))     r.depth     = await syncDepth(year);
            if (feeds.includes("inactives")) r.inactives = await syncInactives(year);
            if (feeds.includes("schedules")) r.schedules = await syncScheduleExtras(year);
            if (feeds.includes("ranks"))     r.ranks     = await syncTeamRanksHistory(year);
            out[String(year)] = r;
        }
        return new Response(JSON.stringify({ ok: true, seasons: out }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        console.error(err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function pickSeasons(body: { seasons?: number[] }): number[] {
    if (body.seasons?.length) return body.seasons.map((s: unknown) => Number(s)).filter(Number.isFinite);
    const now = new Date();
    const cur = now.getUTCMonth() >= 8 ? now.getUTCFullYear() : now.getUTCFullYear() - 1;
    return [cur - 1, cur];
}

async function fetchCsv(url: string): Promise<string[][] | null> {
    const resp = await fetch(url);
    if (!resp.ok) return null;
    return parseCsv(await resp.text());
}

// ---------------- INJURIES ----------------

async function syncInjuries(year: number) {
    const url = INJ_URL.replace("{YEAR}", String(year));
    const rows = await fetchCsv(url);
    if (!rows) return { skipped: "not_published" };
    const header = rows.shift();
    if (!header) return { error: "empty" };
    const ix = {
        season:  header.indexOf("season"),
        week:    header.indexOf("week"),
        gsis:    header.indexOf("gsis_id"),
        status:  header.indexOf("report_status"),
        practice: header.indexOf("practice_status"),
        details: header.indexOf("report_primary_injury"),
    };
    if (ix.gsis < 0) return { error: "missing gsis_id" };

    const out: Array<Record<string, unknown>> = [];
    for (const r of rows) {
        const pid = r[ix.gsis]?.trim();
        if (!pid || pid === "NA") continue;
        const status = (ix.status >= 0 ? r[ix.status] : "")?.trim();
        if (!status || status === "NA") continue;
        out.push({
            season: Math.trunc(num(r[ix.season])),
            week:   Math.trunc(num(r[ix.week])),
            player_id: pid,
            status,
            details: ix.details >= 0 ? nullable(r[ix.details]) : null,
            practice_status: ix.practice >= 0 ? nullable(r[ix.practice]) : null,
            expected_return: null,
        });
    }
    // Wipe + insert for this season (idempotent per-season backfill).
    await supa.from("injury_history").delete().eq("season", year);
    await upsertChunks("injury_history", out, 500, "season,week,player_id");
    return { received: rows.length, written: out.length };
}

// ---------------- DEPTH CHARTS ----------------

async function syncDepth(year: number) {
    const url = DEPTH_URL.replace("{YEAR}", String(year));
    const rows = await fetchCsv(url);
    if (!rows) return { skipped: "not_published" };
    const header = rows.shift();
    if (!header) return { error: "empty" };
    const ix = {
        season:   header.indexOf("season"),
        week:     header.indexOf("week"),
        gsis:     header.indexOf("gsis_id"),
        team:     header.indexOf("club_code") >= 0 ? header.indexOf("club_code") : header.indexOf("team"),
        position: header.indexOf("position"),
        depth:    header.indexOf("depth_team") >= 0 ? header.indexOf("depth_team") : header.indexOf("depth_position"),
        gameType: header.indexOf("game_type"),
    };
    if (ix.gsis < 0 || ix.team < 0) return { error: "missing key columns" };

    const skill = new Set(["QB", "RB", "WR", "TE", "K"]);
    const out: Array<Record<string, unknown>> = [];
    for (const r of rows) {
        if (ix.gameType >= 0 && (r[ix.gameType] ?? "").toUpperCase() !== "REG") continue;
        const pid = r[ix.gsis]?.trim();
        if (!pid || pid === "NA") continue;
        const pos = (r[ix.position] ?? "").toUpperCase();
        if (!skill.has(pos)) continue;
        const depth = numOrNull(r[ix.depth]);
        out.push({
            season: Math.trunc(num(r[ix.season])),
            week:   Math.trunc(num(r[ix.week])),
            team:   (r[ix.team] ?? "").toUpperCase(),
            player_id: pid,
            position: pos,
            depth: depth != null ? Math.round(depth) : 99,
        });
    }
    await supa.from("depth_charts").delete().eq("season", year);
    await upsertChunks("depth_charts", out, 500, "season,week,team,position,player_id");
    return { received: rows.length, written: out.length };
}

// ---------------- INACTIVES ----------------
// Derived from weekly_rosters: any player whose status is RES/IR/SUS/EXE/etc.
// is "inactive that week" for fantasy purposes.

async function syncInactives(year: number) {
    const url = WROST_URL.replace("{YEAR}", String(year));
    const rows = await fetchCsv(url);
    if (!rows) return { skipped: "not_published" };
    const header = rows.shift();
    if (!header) return { error: "empty" };
    const ix = {
        season: header.indexOf("season"),
        week:   header.indexOf("week"),
        gsis:   header.indexOf("gsis_id"),
        status: header.indexOf("status"),
        game:   header.indexOf("game_type"),
    };
    if (ix.gsis < 0) return { error: "missing gsis_id" };

    const inactiveCodes = new Set([
        "RES", "IR", "PUP", "SUS", "EXE", "NON", "NWT", "RET", "INA",
    ]);
    const out: Array<Record<string, unknown>> = [];
    for (const r of rows) {
        if (ix.game >= 0 && (r[ix.game] ?? "").toUpperCase() !== "REG") continue;
        const pid = r[ix.gsis]?.trim();
        if (!pid || pid === "NA") continue;
        const status = (r[ix.status] ?? "").toUpperCase().trim();
        if (!inactiveCodes.has(status)) continue;
        out.push({
            season: Math.trunc(num(r[ix.season])),
            week:   Math.trunc(num(r[ix.week])),
            player_id: pid,
            status,
            reason: null,
        });
    }
    await supa.from("inactives").delete().eq("season", year);
    await upsertChunks("inactives", out, 500, "season,week,player_id");
    return { received: rows.length, written: out.length };
}

// ---------------- SCHEDULE EXTRAS (total, weather, roof, surface) ----------

async function syncScheduleExtras(year: number) {
    const url = SCHED_URL.replace("{YEAR}", String(year));
    const rows = await fetchCsv(url);
    if (!rows) return { skipped: "not_published" };
    const header = rows.shift();
    if (!header) return { error: "empty" };
    const ix = {
        gameID:  header.indexOf("game_id"),
        season:  header.indexOf("season"),
        week:    header.indexOf("week"),
        home:    header.indexOf("home_team"),
        away:    header.indexOf("away_team"),
        spread:  header.indexOf("spread_line"),
        total:   header.indexOf("total_line"),
        temp:    header.indexOf("temp"),
        wind:    header.indexOf("wind"),
        roof:    header.indexOf("roof"),
        surface: header.indexOf("surface"),
        weather: header.indexOf("weather"),  // free-text fallback
        gameType: header.indexOf("game_type"),
    };
    if (ix.gameID < 0) return { error: "missing game_id" };

    let updated = 0;
    for (const r of rows) {
        if (ix.gameType >= 0 && (r[ix.gameType] ?? "").toUpperCase() !== "REG") continue;
        const game_id = r[ix.gameID]?.trim();
        if (!game_id || game_id === "NA") continue;
        const update: Record<string, unknown> = {};
        if (ix.spread >= 0) {
            const s = numOrNull(r[ix.spread]);
            // nflverse spread_line: positive = home favored. Existing
            // home_spread convention in this app: same sign.
            if (s != null) update.home_spread = s;
        }
        if (ix.total >= 0) {
            const t = numOrNull(r[ix.total]);
            if (t != null) update.total = t;
        }
        if (ix.temp >= 0) {
            const t = numOrNull(r[ix.temp]);
            if (t != null) update.temp_f = Math.round(t);
        }
        if (ix.wind >= 0) {
            const w = numOrNull(r[ix.wind]);
            if (w != null) update.wind_mph = Math.round(w);
        }
        if (ix.roof >= 0) {
            const v = nullable(r[ix.roof]);
            if (v) update.roof = v.toLowerCase();
        }
        if (ix.surface >= 0) {
            const v = nullable(r[ix.surface]);
            if (v) update.surface = v.toLowerCase();
        }
        if (ix.weather >= 0) {
            const v = nullable(r[ix.weather]);
            if (v && update.precipitation == null) {
                const lc = v.toLowerCase();
                if (lc.includes("snow")) update.precipitation = "snow";
                else if (lc.includes("rain")) update.precipitation = "rain";
                else if (lc.includes("clear") || lc.includes("sun")) update.precipitation = "clear";
            }
        }
        if (Object.keys(update).length === 0) continue;
        const { error, count } = await supa.from("nfl_schedules")
            .update(update, { count: "exact" }).eq("game_id", game_id);
        if (!error && (count ?? 0) > 0) updated += 1;
    }
    return { received: rows.length, updated };
}

// ---------------- TEAM RANKS HISTORY ----------------
// Walk weeks 1..18; call team_ranks_at_week RPC; upsert into history.

async function syncTeamRanksHistory(year: number) {
    let written = 0;
    for (let w = 1; w <= 18; w++) {
        const { data, error } = await supa.rpc("team_ranks_at_week", {
            p_season: year, p_up_to_week: w
        });
        if (error || !Array.isArray(data) || data.length === 0) continue;
        const rows = data.map((d: Record<string, unknown>) => ({
            season: year, week: w, team: d.team,
            pass_offense: d.pass_offense, rush_offense: d.rush_offense,
            pass_defense: d.pass_defense, rush_defense: d.rush_defense,
        }));
        await supa.from("nfl_team_ranks_history").delete()
            .eq("season", year).eq("week", w);
        await upsertChunks("nfl_team_ranks_history", rows, 500,
            "season,week,team");
        written += rows.length;
    }
    return { written };
}

// ---------------- HELPERS ----------------

async function upsertChunks<T>(table: string, rows: T[], chunk: number, onConflict: string) {
    for (let i = 0; i < rows.length; i += chunk) {
        const slice = rows.slice(i, i + chunk);
        const { error } = await supa.from(table).upsert(slice, { onConflict });
        if (error) throw new Error(`upsert ${table}[${i}..${i+slice.length}]: ${error.message}`);
    }
}

function num(v: string | undefined): number {
    if (!v) return 0;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA") return 0;
    const n = Number(s);
    return Number.isFinite(n) ? n : 0;
}

function numOrNull(v: string | undefined): number | null {
    if (!v) return null;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA") return null;
    const n = Number(s);
    return Number.isFinite(n) ? n : null;
}

function nullable(v: string | undefined): string | null {
    if (!v) return null;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA") return null;
    return s;
}

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
