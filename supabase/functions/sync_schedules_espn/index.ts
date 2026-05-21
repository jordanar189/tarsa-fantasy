// Mirrors the NFL regular-season schedule from ESPN's `site.api.espn.com`
// scoreboard endpoint into nfl_schedules. ESPN publishes the matchups the
// moment the league releases the schedule — ahead of the community nflverse
// games.csv that sync_schedules mirrors — so this is the "earliest available"
// source that makes an upcoming season selectable for draft/league setup.
//
// Key detail: it builds the SAME game_id format nflverse uses
// (`{season}_{week:02d}_{away}_{home}`, with team abbrs normalized to the
// nflverse/nfl_teams convention). Upserts therefore MERGE with sync_schedules
// rows on conflict instead of creating duplicate games. sync_schedules /
// sync_nflverse remain authoritative and refine these rows once they catch up.
//
// Body (optional): { "seasons": [2026] }. Default targets the current NFL
// season + the next one, so it preps the upcoming year during the off-season
// and keeps the current year fresh in-season. No-ops (empty events) until ESPN
// has published a given season, so it's safe to run daily year-round.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ESPN_BASE        = "https://site.api.espn.com/apis/site/v2/sports/football/nfl";
const REG_SEASON_WEEKS = 18;

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

// ESPN abbreviations that differ from the nflverse / nfl_teams convention.
// Only WSH actually occurs for current teams; the rest are historical/defensive
// so a stray relocated-team code can't break the game_id merge with nflverse.
const TEAM_FIXUP: Record<string, string> = {
    WSH: "WAS", LA: "LAR", JAC: "JAX", OAK: "LV", SD: "LAC", STL: "LAR",
};

interface ScheduleRow {
    game_id: string; season: number; week: number;
    home_team: string; away_team: string;
    kickoff: string | null;
    home_score: number | null;
    away_score: number | null;
    status: string;
}

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const seasons: number[] = Array.isArray(body.seasons) && body.seasons.length
            ? body.seasons.map((s: unknown) => Math.trunc(Number(s)))
            : defaultSeasons();

        const results: Record<number, unknown> = {};
        for (const year of seasons) {
            results[year] = await syncSeason(year);
        }
        return ok({ seasons: results });
    } catch (err) {
        console.error(err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function defaultSeasons(): number[] {
    const now = new Date();
    // NFL "season year" is the calendar year of Week 1 (early September).
    const current = now.getUTCMonth() >= 8 ? now.getUTCFullYear() : now.getUTCFullYear() - 1;
    return [current, current + 1];
}

async function syncSeason(year: number): Promise<unknown> {
    const rows: ScheduleRow[] = [];
    for (let week = 1; week <= REG_SEASON_WEEKS; week++) {
        const events = await fetchWeek(year, week);
        for (const ev of events) {
            const row = toRow(ev, year, week);
            if (row) rows.push(row);
        }
    }
    if (rows.length === 0) return { skipped: "no_events_published_yet" };

    const chunk = 500;
    for (let i = 0; i < rows.length; i += chunk) {
        const slice = rows.slice(i, i + chunk);
        const { error } = await supa.from("nfl_schedules")
            .upsert(slice, { onConflict: "game_id" });
        if (error) throw new Error(error.message);
    }
    return { games: rows.length };
}

async function fetchWeek(year: number, week: number): Promise<EspnEvent[]> {
    const url = `${ESPN_BASE}/scoreboard?dates=${year}&seasontype=2&week=${week}`;
    const resp = await fetch(url, { headers: { "User-Agent": "fantasy-football-ios" } });
    // A missing/unreleased week returns 200 with empty events; treat any
    // non-200 as "nothing for this week" rather than failing the whole run.
    if (!resp.ok) return [];
    const json = await resp.json().catch(() => null) as EspnScoreboard | null;
    return json?.events ?? [];
}

function toRow(ev: EspnEvent, year: number, week: number): ScheduleRow | null {
    const comp = ev.competitions?.[0];
    const competitors = comp?.competitors ?? [];
    const homeC = competitors.find((c) => c.homeAway === "home");
    const awayC = competitors.find((c) => c.homeAway === "away");
    const home = fixup(homeC?.team?.abbreviation);
    const away = fixup(awayC?.team?.abbreviation);
    if (!home || !away) return null;

    const state = ev.status?.type?.state;            // pre | in | post
    const completed = ev.status?.type?.completed === true;
    let status = "scheduled";
    if (state === "in") status = "in_progress";
    else if (state === "post" && completed) status = "final";

    const homeScore = status === "scheduled" ? null : numOrNull(homeC?.score);
    const awayScore = status === "scheduled" ? null : numOrNull(awayC?.score);

    return {
        game_id: `${year}_${String(week).padStart(2, "0")}_${away}_${home}`,
        season: year,
        week,
        home_team: home,
        away_team: away,
        kickoff: ev.date ?? null,
        home_score: homeScore,
        away_score: awayScore,
        status,
    };
}

function fixup(abbr: string | undefined): string | null {
    const a = (abbr ?? "").trim().toUpperCase();
    if (!a) return null;
    return TEAM_FIXUP[a] ?? a;
}

function numOrNull(v: string | number | undefined): number | null {
    if (v == null) return null;
    const n = typeof v === "number" ? v : Number(String(v).trim());
    return Number.isFinite(n) ? n : null;
}

function ok(payload: unknown) {
    return new Response(JSON.stringify({ ok: true, ...payload as object }), {
        headers: { "Content-Type": "application/json" }
    });
}

// ----------- ESPN response type sketches (only the bits we touch) -----------

interface EspnScoreboard { events?: EspnEvent[]; }
interface EspnEvent {
    id: string;
    date?: string;
    status?: { type?: { state?: string; completed?: boolean } };
    competitions?: Array<{
        competitors?: Array<{
            homeAway?: string;
            score?: string | number;
            team?: { abbreviation?: string };
        }>;
    }>;
}
