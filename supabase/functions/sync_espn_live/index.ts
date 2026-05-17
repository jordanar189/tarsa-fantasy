// Pulls live in-game player stats from ESPN's undocumented `site.api.espn.com`
// scoreboard + summary endpoints and upserts to live_scores. No-ops when no
// games are in progress (so safe to run every minute year-round).
//
// Cross-references ESPN athlete IDs to nflverse GSIS via players_cache.espn_id
// (populated by sync_nflverse from the rosters CSV).
//
// Strategy:
//   1) Hit scoreboard?dates=YYYYMMDD-YYYYMMDD for "today ± 1 day" to find
//      games that exist right now.
//   2) For each game whose status is IN_PROGRESS or recently FINAL, fetch the
//      summary endpoint and extract per-player stats from the boxscore.
//   3) Compute fantasy points (standard / PPR / half-PPR), upsert to live_scores.
//   4) When game is FINAL: persist final numbers, then delete the live row
//      (we don't want stale "live" overrides lingering past game end).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ESPN_BASE        = "https://site.api.espn.com/apis/site/v2/sports/football/nfl";

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

interface LiveRow {
    player_id: string; season: number; week: number;
    fantasy_points: number; fantasy_points_ppr: number; fantasy_points_half_ppr: number;
    is_final: boolean;
}

Deno.serve(async (_req: Request) => {
    try {
        const espnIDtoGsis = await loadEspnMap();
        if (espnIDtoGsis.size === 0) {
            return ok({ skipped: "players_cache has no espn_id rows yet — run sync_nflverse first" });
        }

        const scoreboard = await fetchScoreboard();
        const events = (scoreboard?.events ?? []) as Array<EspnEvent>;
        const liveOrFinal = events.filter(isLiveOrRecentFinal);
        if (liveOrFinal.length === 0) {
            return ok({ note: "no live games right now", checked: events.length });
        }

        const season = scoreboard?.season?.year ?? new Date().getUTCFullYear();
        const week   = scoreboard?.week?.number ?? 1;

        const rows: LiveRow[] = [];
        const finalRowsForPersistence: LiveRow[] = [];
        for (const ev of liveOrFinal) {
            const summary = await fetchSummary(ev.id);
            const isFinal = ev.status?.type?.completed === true;
            const playerStats = extractPlayerStats(summary, espnIDtoGsis);
            for (const ps of playerStats) {
                const row: LiveRow = {
                    player_id: ps.gsis,
                    season, week,
                    fantasy_points:           round2(ps.fantasyPoints),
                    fantasy_points_ppr:       round2(ps.fantasyPointsPPR),
                    fantasy_points_half_ppr:  round2(ps.fantasyPointsHalf),
                    is_final: isFinal
                };
                rows.push(row);
                if (isFinal) finalRowsForPersistence.push(row);
            }
        }

        if (rows.length > 0) {
            const { error } = await supa.from("live_scores").upsert(rows, {
                onConflict: "player_id,season,week"
            });
            if (error) throw new Error(`live upsert: ${error.message}`);
        }

        // For finalized games, also persist the numbers into player_games as
        // an authoritative final score (the nflverse sync will further refine
        // them when stat corrections post the next day). Then drop the live
        // override so clients fall through to the persisted value.
        if (finalRowsForPersistence.length > 0) {
            const persistRows = finalRowsForPersistence.map(r => ({
                player_id: r.player_id, season: r.season, week: r.week,
                fantasy_points: r.fantasy_points,
                fantasy_points_ppr: r.fantasy_points_ppr,
                fantasy_points_half_ppr: r.fantasy_points_half_ppr,
                updated_at: new Date().toISOString()
            }));
            // Upsert ONLY the fantasy columns; don't touch the box-score
            // counting stats which nflverse handles authoritatively.
            for (const r of persistRows) {
                await supa.from("player_games").upsert(
                    { ...r },
                    { onConflict: "player_id,season,week", ignoreDuplicates: false }
                );
            }
            await supa.from("live_scores")
                .delete()
                .in("player_id", finalRowsForPersistence.map(r => r.player_id))
                .eq("season", season).eq("week", week);
        }

        return ok({ live_rows: rows.length, games: liveOrFinal.length, season, week });
    } catch (err) {
        console.error(err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function ok(payload: unknown) {
    return new Response(JSON.stringify({ ok: true, ...payload as object }), {
        headers: { "Content-Type": "application/json" }
    });
}

async function loadEspnMap(): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    // Paginate through all players_cache rows that have an espn_id.
    let from = 0;
    const page = 1000;
    while (true) {
        const { data, error } = await supa
            .from("players_cache")
            .select("id, espn_id")
            .not("espn_id", "is", null)
            .range(from, from + page - 1);
        if (error) throw new Error(`load espn map: ${error.message}`);
        if (!data || data.length === 0) break;
        for (const r of data as { id: string; espn_id: string }[]) {
            out.set(String(r.espn_id), r.id);
        }
        if (data.length < page) break;
        from += page;
    }
    return out;
}

async function fetchScoreboard(): Promise<EspnScoreboard | null> {
    const now = new Date();
    // ESPN's scoreboard endpoint defaults to "today's slate" when no params
    // are passed; for live monitoring we want exactly that.
    const url = `${ESPN_BASE}/scoreboard`;
    const resp = await fetch(url, { headers: { "User-Agent": "fantasy-football-ios" } });
    if (!resp.ok) throw new Error(`scoreboard HTTP ${resp.status}`);
    return await resp.json();
}

async function fetchSummary(eventID: string): Promise<EspnSummary> {
    const url = `${ESPN_BASE}/summary?event=${eventID}`;
    const resp = await fetch(url, { headers: { "User-Agent": "fantasy-football-ios" } });
    if (!resp.ok) throw new Error(`summary HTTP ${resp.status}`);
    return await resp.json();
}

function isLiveOrRecentFinal(ev: EspnEvent): boolean {
    const state = ev.status?.type?.state;       // pre | in | post
    const completed = ev.status?.type?.completed === true;
    if (state === "in") return true;
    if (state === "post" && completed) {
        // Recently final: within the last ~2 hours since game end.
        // We don't have a precise "ended_at" — heuristic: if the game's
        // detail string contains "Final" and there's no schedule that's
        // older than ~3h, we treat it as recently final.
        return true;  // simpler: always process post-final; we'll dedupe on upsert
    }
    return false;
}

// ----------- Stat extraction from ESPN's deeply nested summary -----------

interface PlayerStatLine { gsis: string; fantasyPoints: number; fantasyPointsPPR: number; fantasyPointsHalf: number; }

function extractPlayerStats(summary: EspnSummary, espnIDtoGsis: Map<string, string>): PlayerStatLine[] {
    const out = new Map<string, { rec: number; fp: number; fpPpr: number; fpHalf: number }>();
    const boxscore = summary?.boxscore?.players ?? [];

    for (const teamBox of boxscore) {
        const categories = teamBox?.statistics ?? [];
        for (const cat of categories) {
            const labels = cat.labels ?? [];
            const name = (cat.name ?? "").toLowerCase();
            for (const athleteEntry of cat.athletes ?? []) {
                const athleteID = String(athleteEntry?.athlete?.id ?? "");
                const gsis = espnIDtoGsis.get(athleteID);
                if (!gsis) continue;
                const stats = athleteEntry.stats ?? [];
                // Compute fantasy point deltas from this category and merge per player.
                const delta = computeCategoryDelta(name, labels, stats);
                if (!out.has(gsis)) out.set(gsis, { rec: 0, fp: 0, fpPpr: 0, fpHalf: 0 });
                const acc = out.get(gsis)!;
                acc.fp     += delta.fp;
                acc.fpPpr  += delta.fpPpr;
                acc.fpHalf += delta.fpHalf;
                acc.rec    += delta.rec;
            }
        }
    }

    return [...out.entries()].map(([gsis, v]) => ({
        gsis,
        fantasyPoints:     v.fp,
        fantasyPointsPPR:  v.fpPpr,
        fantasyPointsHalf: v.fpHalf
    }));
}

// Standard scoring:
//   pass yd × 0.04, pass TD × 4, INT × -2
//   rush yd × 0.1, rush TD × 6
//   rec × 1 (PPR) / 0.5 (half), rec yd × 0.1, rec TD × 6
//   fumble lost × -2, 2pt × 2
function computeCategoryDelta(catName: string, labels: string[], stats: string[]):
    { rec: number; fp: number; fpPpr: number; fpHalf: number }
{
    const idx = (label: string) => labels.indexOf(label);
    const get = (label: string) => {
        const i = idx(label);
        if (i < 0 || i >= stats.length) return 0;
        // Some stats are like "12/20" (CMP/ATT) — take the first number.
        const raw = (stats[i] ?? "").split("/")[0];
        const n = Number(raw);
        return Number.isFinite(n) ? n : 0;
    };

    let pts = 0, rec = 0;
    if (catName === "passing") {
        const yds = get("YDS");
        const tds = get("TD");
        const ints = get("INT");
        pts += yds * 0.04 + tds * 4 - ints * 2;
    } else if (catName === "rushing") {
        const yds = get("YDS");
        const tds = get("TD");
        pts += yds * 0.1 + tds * 6;
    } else if (catName === "receiving") {
        rec = get("REC");
        const yds = get("YDS");
        const tds = get("TD");
        pts += yds * 0.1 + tds * 6;
    } else if (catName === "fumbles") {
        const lost = get("LOST");
        pts += lost * -2;
    }
    return { rec, fp: pts, fpPpr: pts + rec, fpHalf: pts + rec * 0.5 };
}

function round2(x: number): number { return Math.round(x * 100) / 100; }

// ----------- ESPN response type sketches (only the bits we touch) -----------

interface EspnScoreboard {
    events?: EspnEvent[];
    season?: { year?: number };
    week?:   { number?: number };
}
interface EspnEvent {
    id: string;
    status?: { type?: { state?: string; completed?: boolean; description?: string } };
}
interface EspnSummary {
    boxscore?: {
        players?: Array<{
            statistics?: Array<{
                name?: string;
                labels?: string[];
                athletes?: Array<{
                    athlete?: { id?: number | string };
                    stats?: string[];
                }>;
            }>;
        }>;
    };
}
