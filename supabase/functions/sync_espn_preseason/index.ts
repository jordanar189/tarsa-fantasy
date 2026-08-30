// Preseason game + player stat tracking from ESPN's scoreboard/summary
// endpoints into preseason_games / preseason_player_stats, with one Realtime
// broadcast per run so clients refresh what they're looking at.
//
// Modes (POST body, default "live"):
//   live      – the current scoreboard slate; upserts every preseason game on
//               it and pulls box scores for games in progress or newly final.
//               Cron runs this every minute inside a preseason game window.
//   schedule  – all preseason weeks for the current + next season, games only
//               (no box scores). Cron runs this daily; it no-ops until ESPN
//               publishes the slate.
//   backfill  – like schedule but also pulls box scores for every final game
//               not yet processed. One-off, e.g. {"mode":"backfill","season":2026}.
//
// Preseason lives in its own tables (see the migration header) and never
// touches live_scores / player_games / league scoring.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { fetchWithTimeout, withJobLock } from "../_shared/jobs.ts";
import {
    STAT_COLUMNS, compactScoringPlays, extractBoxScore, gameRowFromEvent,
    isPreseason, preseasonWeekLabel,
} from "./parse.ts";
import type { EspnBoxSummary, EspnEvent, EspnScoreboard, GameRow } from "./parse.ts";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Same relay arrangement as sync_espn_live: ESPN 403s the edge runtime's
// egress, so production sets ESPN_RELAY_BASE/ESPN_RELAY_KEY.
const ESPN_DIRECT_BASE = "https://site.api.espn.com/apis/site/v2/sports/football/nfl";
const ESPN_BASE        = (Deno.env.get("ESPN_RELAY_BASE") ?? ESPN_DIRECT_BASE).replace(/\/+$/, "");
const ESPN_RELAY_KEY   = Deno.env.get("ESPN_RELAY_KEY") ?? "";
const ESPN_HEADERS: Record<string, string> = {
    "User-Agent": "fantasy-football-ios",
    ...(ESPN_RELAY_KEY ? { "X-Relay-Key": ESPN_RELAY_KEY } : {}),
};
const ESPN_TIMEOUT_MS  = 10_000;
const MAX_PRE_WEEKS    = 5;      // ESPN uses 1..4; 5 is a guard for odd calendars

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: fetchWithTimeout() },
});

type Mode = "live" | "schedule" | "backfill";

interface RunTotals { games: number; box_scores: number; finals: number; stat_rows: number; }

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const mode: Mode = body.mode === "schedule" || body.mode === "backfill" ? body.mode : "live";
        const season = Number.isFinite(Number(body.season)) && body.season != null
            ? Math.trunc(Number(body.season)) : null;
        const out = await withJobLock(supa, "sync_espn_preseason", () => run(mode, season));
        return ok(out ?? { skipped: "previous run still going" });
    } catch (err) {
        console.error(err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

async function run(mode: Mode, seasonOverride: number | null): Promise<Record<string, unknown>> {
    if (mode === "live") {
        const sb = await fetchScoreboard("");
        const events = (sb.events ?? []).filter(ev => isPreseason(ev, sb.season?.type));
        if (events.length === 0) {
            return { mode, note: "no preseason games on the current slate", checked: sb.events?.length ?? 0 };
        }
        const totals = await processEvents(sb, events, true);
        return { mode, ...totals };
    }

    const seasons = seasonOverride != null ? [seasonOverride] : defaultSeasons();
    const results: Record<number, RunTotals | { skipped: string }> = {};
    for (const year of seasons) {
        const totals: RunTotals = { games: 0, box_scores: 0, finals: 0, stat_rows: 0 };
        for (let week = 1; week <= MAX_PRE_WEEKS; week++) {
            const sb = await fetchScoreboard(`?dates=${year}&seasontype=1&week=${week}`);
            const events = (sb.events ?? []).filter(ev => isPreseason(ev, sb.season?.type));
            if (events.length === 0) continue;
            const t = await processEvents(sb, events, mode === "backfill");
            totals.games += t.games; totals.box_scores += t.box_scores;
            totals.finals += t.finals; totals.stat_rows += t.stat_rows;
        }
        results[year] = totals.games === 0 ? { skipped: "no_events_published_yet" } : totals;
    }
    return { mode, seasons: results };
}

// Upserts the game rows for `events`, then (optionally) box scores for games
// in progress or newly final, then broadcasts once if anything live changed.
async function processEvents(sb: EspnScoreboard, events: EspnEvent[], withBoxScores: boolean): Promise<RunTotals> {
    const now = new Date();
    const rows: GameRow[] = [];
    for (const ev of events) {
        const row = gameRowFromEvent(ev, preseasonWeekLabel(sb, ev.week?.number ?? 0), now);
        if (row) rows.push(row);
    }
    if (rows.length > 0) {
        const { error } = await supa.from("preseason_games").upsert(rows, { onConflict: "game_id" });
        if (error) throw new Error(`preseason_games upsert: ${error.message}`);
    }
    const totals: RunTotals = { games: rows.length, box_scores: 0, finals: 0, stat_rows: 0 };
    if (!withBoxScores) return totals;

    const processed = await loadProcessedEventIDs(events.map(e => e.id));
    const touched: string[] = [];
    let espnIDtoGsis: Map<string, string> | null = null;
    let broadcastSeason = 0, broadcastWeek = 0;

    for (const ev of events) {
        const live = ev.status?.type?.state === "in";
        const final = ev.status?.type?.completed === true && ev.status?.type?.state === "post";
        if (!live && !(final && !processed.has(ev.id))) continue;
        const season = ev.season?.year, preWeek = ev.week?.number;
        if (!season || !preWeek) continue;
        espnIDtoGsis ??= await loadEspnMap();

        const summary = await fetchSummary(ev.id);
        const lines = extractBoxScore(summary);
        const statRows = lines.map(l => ({
            game_id: ev.id,
            espn_athlete_id: l.espnAthleteID,
            season, pre_week: preWeek,
            player_id: espnIDtoGsis!.get(l.espnAthleteID) ?? null,
            name: l.name, jersey: l.jersey, team: l.team, opponent: l.opponent,
            is_final: final,
            ...Object.fromEntries(STAT_COLUMNS.map(c => [c, l.stats[c] ?? 0])),
            fantasy_points: l.stats.fantasy_points ?? 0,
            fantasy_points_ppr: l.stats.fantasy_points_ppr ?? 0,
            fantasy_points_half_ppr: l.stats.fantasy_points_half_ppr ?? 0,
            updated_at: now.toISOString(),
        }));
        for (let i = 0; i < statRows.length; i += 500) {
            const { error } = await supa.from("preseason_player_stats")
                .upsert(statRows.slice(i, i + 500), { onConflict: "game_id,espn_athlete_id" });
            if (error) throw new Error(`preseason_player_stats upsert: ${error.message}`);
        }
        const { error: spErr } = await supa.from("preseason_games")
            .update({ scoring_plays: compactScoringPlays(summary), updated_at: now.toISOString() })
            .eq("game_id", ev.id);
        if (spErr) throw new Error(`scoring_plays update: ${spErr.message}`);

        if (final) {
            const { error } = await supa.from("espn_processed_games")
                .upsert({ event_id: ev.id, season, week: preWeek }, { onConflict: "event_id" });
            if (error) throw new Error(`espn_processed_games: ${error.message}`);
            totals.finals += 1;
        }
        totals.box_scores += 1;
        totals.stat_rows += statRows.length;
        touched.push(ev.id);
        broadcastSeason = season; broadcastWeek = preWeek;
    }

    if (touched.length > 0) {
        const { error } = await supa.rpc("preseason_broadcast", {
            p_season: broadcastSeason, p_pre_week: broadcastWeek, p_game_ids: touched,
        });
        if (error) console.error(`preseason_broadcast: ${error.message}`);   // data is saved; a missed push is recoverable
    }
    return totals;
}

// ----------- helpers -----------

function defaultSeasons(): number[] {
    // Preseason runs in August, so the "current" NFL season year is the
    // calendar year from July onward.
    const now = new Date();
    const current = now.getUTCMonth() >= 6 ? now.getUTCFullYear() : now.getUTCFullYear() - 1;
    return [current, current + 1];
}

async function loadEspnMap(): Promise<Map<string, string>> {
    const { data, error } = await supa.rpc("espn_id_map");
    if (error) throw new Error(`espn_id_map: ${error.message}`);
    return new Map(Object.entries((data ?? {}) as Record<string, string>));
}

async function loadProcessedEventIDs(eventIDs: string[]): Promise<Set<string>> {
    if (eventIDs.length === 0) return new Set();
    const { data, error } = await supa.from("espn_processed_games")
        .select("event_id").in("event_id", eventIDs);
    if (error) throw new Error(`espn_processed_games: ${error.message}`);
    return new Set(((data ?? []) as { event_id: string }[]).map(r => r.event_id));
}

async function fetchScoreboard(query: string): Promise<EspnScoreboard> {
    const resp = await fetch(`${ESPN_BASE}/scoreboard${query}`, {
        headers: ESPN_HEADERS, signal: AbortSignal.timeout(ESPN_TIMEOUT_MS),
    });
    if (!resp.ok) throw new Error(`scoreboard HTTP ${resp.status}`);
    return await resp.json();
}

async function fetchSummary(eventID: string): Promise<EspnBoxSummary> {
    const resp = await fetch(`${ESPN_BASE}/summary?event=${eventID}`, {
        headers: ESPN_HEADERS, signal: AbortSignal.timeout(ESPN_TIMEOUT_MS),
    });
    if (!resp.ok) throw new Error(`summary HTTP ${resp.status}`);
    return await resp.json();
}

function ok(payload: unknown) {
    return new Response(JSON.stringify({ ok: true, ...payload as object }), {
        headers: { "Content-Type": "application/json" }
    });
}
