// Pulls live in-game player stats from ESPN's undocumented `site.api.espn.com`
// scoreboard + summary endpoints and upserts to live_scores. No-ops when no
// games are in progress (so safe to run every minute year-round).
//
// Cross-references ESPN athlete IDs to nflverse GSIS via players_cache.espn_id
// (populated by sync_nflverse from the rosters CSV).
//
// Strategy, per regular-season game that is live or newly final:
//   1) Parse the box score into RAW counting stats (passing / rushing /
//      receiving / fumbles / kicking) per player — custom-scoring leagues
//      and K/DST scoring compute from raw columns, so points alone are
//      useless to them. FG distances come from the scoring plays (the box
//      score only carries makes/attempts).
//   2) Synthesize a DEF_<TEAM> row per side: sacks / INTs / fumble
//      recoveries from the OPPONENT's offensive box score, defensive and
//      return TDs + safeties from the scoring plays, points allowed from
//      the live score.
//   3) Compute the three preset point fields (offense only, mirroring
//      nflverse's convention — K/DST points always derive from raw columns).
//   4) Mirror the game's live score/status onto nfl_schedules so Game
//      Center and the trade-lock check track reality between the daily
//      schedule syncs.
//   5) When a game goes final: persist the full stat line into player_games
//      (nflverse refines it next morning), delete the live rows, and record
//      the event in espn_processed_games so the game is processed exactly
//      once instead of re-churning through Realtime every minute all day.
//
// The parsing itself lives in parse.ts (pure, deno-testable).

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
    makeRow, extractPlayerStats, applyFieldGoalDistances, synthesizeDST, fixTeam,
    parseLivePlays, currentRedZone, LIVE_PLAY_ID_BASE,
} from "./parse.ts";
import type { LiveRow, EspnSummary } from "./parse.ts";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ESPN_BASE        = "https://site.api.espn.com/apis/site/v2/sports/football/nfl";

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

Deno.serve(async (_req: Request) => {
    try {
        const espnIDtoGsis = await loadEspnMap();
        if (espnIDtoGsis.size === 0) {
            return ok({ skipped: "players_cache has no espn_id rows yet — run sync_nflverse first" });
        }

        const scoreboard = await fetchScoreboard();
        const events = (scoreboard?.events ?? []) as Array<EspnEvent>;
        // Regular season only. Preseason (type 1) and postseason (type 3) both
        // restart week.number at 1 — writing those rows would poison the real
        // Week 1 stats in live_scores AND player_games. The app only scores
        // REG weeks (nflverse REG rows), so anything else is skipped outright.
        const scoreboardType = scoreboard?.season?.type;
        const candidates = events.filter(ev =>
            isRegularSeason(ev, scoreboardType) && isLiveOrFinal(ev)
        );
        if (candidates.length === 0) {
            return ok({
                note: "no live regular-season games right now",
                checked: events.length, seasonType: scoreboardType ?? null
            });
        }

        // Finals already persisted are done — don't re-fetch or re-churn them.
        const processed = await loadProcessedEventIDs(candidates.map(e => e.id));
        const games = candidates.filter(ev =>
            !(ev.status?.type?.completed === true && processed.has(ev.id))
        );
        if (games.length === 0) {
            return ok({ note: "all finals already persisted", checked: events.length });
        }

        const season = scoreboard?.season?.year ?? new Date().getUTCFullYear();
        const week   = scoreboard?.week?.number ?? 1;

        let liveRows = 0, finals = 0;
        for (const ev of games) {
            const n = await processGame(ev, season, week, espnIDtoGsis);
            liveRows += n.rows;
            if (n.final) finals += 1;
        }
        return ok({ live_rows: liveRows, games: games.length, finals, season, week });
    } catch (err) {
        console.error(err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

async function processGame(
    ev: EspnEvent, season: number, week: number, espnIDtoGsis: Map<string, string>
): Promise<{ rows: number; final: boolean }> {
    const isFinal = ev.status?.type?.completed === true;
    const summary = await fetchSummary(ev.id);

    // Sides: abbreviations + current scores from the scoreboard event.
    const comp = ev.competitions?.[0];
    const sides = (comp?.competitors ?? []).map(c => ({
        team: fixTeam(c.team?.abbreviation ?? ""),
        homeAway: c.homeAway ?? "",
        score: Number(c.score ?? 0),
    }));
    const home = sides.find(s => s.homeAway === "home");
    const away = sides.find(s => s.homeAway === "away");

    // Player stat lines from the box score + FG distances from scoring plays.
    const lines = extractPlayerStats(summary, espnIDtoGsis);
    applyFieldGoalDistances(summary, lines);

    // Team-defense rows.
    const dstLines = synthesizeDST(summary, home, away);

    const rows: LiveRow[] = [];
    for (const [gsis, stats] of lines) {
        rows.push(makeRow(gsis, season, week, stats, isFinal));
    }
    for (const [defID, stats] of dstLines) {
        rows.push(makeRow(defID, season, week, stats, isFinal));
    }

    if (rows.length > 0) {
        const { error } = await supa.from("live_scores").upsert(rows, {
            onConflict: "player_id,season,week"
        });
        if (error) throw new Error(`live upsert: ${error.message}`);
    }

    // Mirror score/status onto the schedule row (Game Center + trade locks).
    if (home && away && home.team && away.team) {
        const gameID = `${season}_${String(week).padStart(2, "0")}_${away.team}_${home.team}`;
        await supa.from("nfl_schedules").update({
            home_score: home.score,
            away_score: away.score,
            status: isFinal ? "final" : "in_progress",
            updated_at: new Date().toISOString(),
        }).eq("game_id", gameID);

        if (!isFinal) {
            // Live play-by-play: mirror the summary's drives into plays under
            // synthetic high ids so the Gamecast works during the game. Never
            // fatal — the score pipeline matters more than the play feed.
            try {
                const livePlays = parseLivePlays(summary, gameID, season, week, home.team, away.team);
                if (livePlays.length > 0) {
                    const { error } = await supa.from("plays")
                        .upsert(livePlays, { onConflict: "game_id,play_id" });
                    if (error) console.error(`live plays: ${error.message}`);
                }
            } catch (err) {
                console.error(`live plays: ${err}`);
            }
            try {
                await maybeRedZoneAlert(summary, ev.id);
            } catch (err) {
                console.error(`red zone: ${err}`);
            }
        } else {
            // Sweep the synthetic live rows; nflverse's authoritative
            // play-by-play lands the next morning.
            await supa.from("plays").delete()
                .eq("game_id", gameID)
                .gte("play_id", LIVE_PLAY_ID_BASE);
        }
    }

    if (isFinal) {
        // Red-zone dedupe rows for this game are done with.
        await supa.from("red_zone_alerts").delete().eq("event_id", ev.id);
    }
    if (isFinal && rows.length > 0) {
        // Persist the full final stat line — better than nothing for the
        // hours until nflverse's authoritative sync overwrites it.
        const persist = rows.map(r => {
            const { is_final: _drop, ...rest } = r;
            return { ...rest, updated_at: new Date().toISOString() };
        });
        for (const r of persist) {
            await supa.from("player_games").upsert(r, {
                onConflict: "player_id,season,week", ignoreDuplicates: false
            });
        }
        await supa.from("live_scores")
            .delete()
            .in("player_id", rows.map(r => r.player_id))
            .eq("season", season).eq("week", week);
        await supa.from("espn_processed_games").upsert({
            event_id: ev.id, season, week,
        }, { onConflict: "event_id" });
    }
    return { rows: rows.length, final: isFinal };
}

// One push per (game, drive): "your starter's offense is inside the 20".
// The red_zone_alerts insert doubles as the claim — a concurrent run that
// loses the PK race just skips.
async function maybeRedZoneAlert(summary: EspnSummary, eventID: string) {
    const rz = currentRedZone(summary);
    if (!rz) return;

    const { error: claimErr } = await supa.from("red_zone_alerts")
        .insert({ event_id: eventID, drive_id: rz.driveID });
    if (claimErr) return;   // already alerted for this drive

    const { data: teamPlayers } = await supa.from("players_cache")
        .select("id, name")
        .eq("team", rz.team);
    const nameByID = new Map(
        ((teamPlayers ?? []) as Array<{ id: string; name: string }>).map(p => [p.id, p.name])
    );
    if (nameByID.size === 0) return;

    const { data: teams } = await supa.from("teams")
        .select("owner_id, league_id, starters, leagues!inner(is_test, season_completed)")
        .overlaps("starters", [...nameByID.keys()])
        .not("owner_id", "is", null)
        .eq("leagues.is_test", false)
        .eq("leagues.season_completed", false);

    const events: Array<{ user_id: string; title: string; body: string; deep_link: string }> = [];
    const seen = new Set<string>();
    for (const t of (teams ?? []) as Array<{ owner_id: string; league_id: string; starters: string[] }>) {
        if (!t.owner_id || seen.has(t.owner_id)) continue;
        const mine = (t.starters ?? []).filter(pid => nameByID.has(pid));
        if (mine.length === 0) continue;
        seen.add(t.owner_id);
        const first = nameByID.get(mine[0]) ?? mine[0];
        const who = mine.length === 1 ? first : `${first} +${mine.length - 1}`;
        events.push({
            user_id: t.owner_id,
            title: "Red zone",
            body: `${rz.team} is inside the 20 — ${who} in range to score.`,
            deep_link: `tarsafantasy://league/${t.league_id}`,
        });
    }
    if (events.length > 0) {
        const { error } = await supa.from("push_events").insert(events);
        if (error) console.error(`red zone push: ${error.message}`);
    }
}

// ----------- Fetch helpers -----------

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

async function loadProcessedEventIDs(eventIDs: string[]): Promise<Set<string>> {
    if (eventIDs.length === 0) return new Set();
    const { data } = await supa.from("espn_processed_games")
        .select("event_id")
        .in("event_id", eventIDs);
    return new Set(((data ?? []) as { event_id: string }[]).map(r => r.event_id));
}

async function fetchScoreboard(): Promise<EspnScoreboard | null> {
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

// ESPN season types: 1 = preseason, 2 = regular season, 3 = postseason.
// Prefer the event's own season.type; fall back to the scoreboard-level type.
// If neither is present (unexpected), skip the game — a missed minute of live
// scores is recoverable, corrupted Week 1 rows are not.
function isRegularSeason(ev: EspnEvent, scoreboardType: number | undefined): boolean {
    const t = ev.season?.type ?? scoreboardType;
    return t === 2;
}

function isLiveOrFinal(ev: EspnEvent): boolean {
    const state = ev.status?.type?.state;       // pre | in | post
    const completed = ev.status?.type?.completed === true;
    return state === "in" || (state === "post" && completed);
}

function ok(payload: unknown) {
    return new Response(JSON.stringify({ ok: true, ...payload as object }), {
        headers: { "Content-Type": "application/json" }
    });
}

// ----------- ESPN response type sketches (only the bits we touch) -----------

interface EspnScoreboard {
    events?: EspnEvent[];
    season?: { year?: number; type?: number };
    week?:   { number?: number };
}
interface EspnEvent {
    id: string;
    season?: { year?: number; type?: number };
    status?: { type?: { state?: string; completed?: boolean; description?: string } };
    competitions?: Array<{
        competitors?: Array<{
            homeAway?: string;
            score?: string | number;
            team?: { abbreviation?: string };
        }>;
    }>;
}
