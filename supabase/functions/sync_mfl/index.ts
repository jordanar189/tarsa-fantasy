// Mirrors MyFantasyLeague (MFL) public endpoints into our DB. One function
// covers four feeds because they share the same prerequisite — a MFL→nflverse
// player ID map — which is expensive to build and we don't want to repeat.
//
// Feeds:
//   • injuries           → public.injuries          (snapshot, truncate + insert)
//   • topAdds / topDrops → public.trending_players  (snapshot, truncate + insert)
//   • adp                → public.adp                (upsert by season+scoring+player)
//   • nflSchedule        → public.nfl_schedules (spread) + public.nfl_team_ranks
//   • topStarters        → public.most_started      (snapshot, truncate + insert)
//
// Body (all optional):
//   { "seasons": [2026, 2024, ...] }   // ADP backfill; defaults to [current_year]
//   { "feeds": ["injuries","trending","adp","schedule","most_started"] }
//
// MFL gives "Last, First" names, uses some team aliases that differ from
// nflverse (KCC vs KC, etc.), and uses 'PK' for kicker. Normalization is
// applied inline. Players that don't resolve to a nflverse ID are skipped
// silently — match rate is ~99% with the alias+fallback strategy.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MFL_BASE         = "https://api.myfantasyleague.com";
const USER_AGENT       = "Tarsa-Fantasy-Sync/0.1";

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

// Team-code aliases. MFL uses some 3-letter codes that don't match nflverse.
const TEAM_ALIAS: Record<string, string> = {
    KCC: "KC", NOS: "NO", TBB: "TB", NEP: "NE", LVR: "LV",
    GBP: "GB", SFO: "SF", JAC: "JAX", ARZ: "ARI", CLV: "CLE",
    HST: "HOU", BLT: "BAL", LA: "LAR",
};

// Position aliases. MFL uses PK for kicker; rest match.
const POS_ALIAS: Record<string, string> = { PK: "K" };

interface MflPlayer { id: string; name: string; position: string; team: string; }
interface CachePlayer { id: string; name: string; position: string | null; team: string | null; }

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const feedsRequested: string[] = Array.isArray(body.feeds) ? body.feeds
            : ["injuries", "trending", "adp", "schedule", "most_started"];
        const seasons: number[] = Array.isArray(body.seasons) && body.seasons.length > 0
            ? body.seasons.map((s: unknown) => Number(s)).filter(Number.isFinite)
            : [new Date().getUTCFullYear()];

        // Build the ID resolver up front — every feed needs it.
        const idMap = await buildIdResolver(seasons[0]);
        const result: Record<string, unknown> = {};

        if (feedsRequested.includes("injuries")) {
            result.injuries = await syncInjuries(idMap);
        }
        if (feedsRequested.includes("trending")) {
            result.trending = await syncTrending(idMap);
        }
        if (feedsRequested.includes("adp")) {
            const adpResults: Record<string, unknown> = {};
            for (const season of seasons) {
                for (const scoring of ["ppr", "standard", "half"] as const) {
                    adpResults[`${season}/${scoring}`] = await syncAdp(season, scoring, idMap);
                }
            }
            result.adp = adpResults;
        }
        if (feedsRequested.includes("schedule")) {
            // Always sync the current NFL year — spreads + ranks are forward-
            // looking signals, not historical archive material.
            result.schedule = await syncSchedule(new Date().getUTCFullYear());
        }
        if (feedsRequested.includes("most_started")) {
            result.most_started = await syncMostStarted(idMap);
        }
        return new Response(JSON.stringify({ ok: true, result }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

// MFL → nflverse ID resolver. Pulls MFL's player directory + our players_cache
// once, then returns a closure that maps MFL player IDs to nflverse IDs.
async function buildIdResolver(year: number): Promise<(mflID: string) => string | null> {
    const mflResp = await fetch(`${MFL_BASE}/${year}/export?TYPE=players&JSON=1`,
                                { headers: { "User-Agent": USER_AGENT } });
    if (!mflResp.ok) throw new Error(`MFL players: HTTP ${mflResp.status}`);
    const mflDir = (await mflResp.json()).players?.player ?? [] as MflPlayer[];

    const cache: CachePlayer[] = [];
    const pageSize = 1000;
    for (let from = 0; ; from += pageSize) {
        const { data, error } = await supa.from("players_cache")
            .select("id, name, position, team")
            .range(from, from + pageSize - 1);
        if (error) throw new Error(`players_cache: ${error.message}`);
        const rows = (data ?? []) as CachePlayer[];
        cache.push(...rows);
        if (rows.length < pageSize) break;
    }

    // Index our cache by (norm_name, position, team) with a name+position fallback.
    const tripleKey = new Map<string, string>();
    const pairKey   = new Map<string, string>();
    for (const p of cache) {
        if (!p.position) continue;
        const n = normalizeName(p.name);
        const po = p.position.toUpperCase();
        const t = (p.team ?? "").toUpperCase();
        tripleKey.set(`${n}|${po}|${t}`, p.id);
        pairKey.set(`${n}|${po}`, p.id);
    }

    // Pre-resolve every MFL ID we might see, since the feeds use these IDs.
    const resolved = new Map<string, string>();
    for (const m of mflDir) {
        const pos = (POS_ALIAS[m.position?.toUpperCase()] ?? m.position?.toUpperCase()) ?? "";
        if (!["QB","RB","WR","TE","K"].includes(pos)) continue;
        const name = mflToFirstLast(m.name);
        const n = normalizeName(name);
        const teamRaw = (m.team ?? "").toUpperCase();
        const team = TEAM_ALIAS[teamRaw] ?? teamRaw;
        const hit = tripleKey.get(`${n}|${pos}|${team}`)
                 ?? pairKey.get(`${n}|${pos}`);
        if (hit) resolved.set(m.id, hit);
    }
    return (mflID: string) => resolved.get(mflID) ?? null;
}

async function syncInjuries(resolve: (id: string) => string | null) {
    const year = new Date().getUTCFullYear();
    const resp = await fetch(`${MFL_BASE}/${year}/export?TYPE=injuries&JSON=1`,
                             { headers: { "User-Agent": USER_AGENT } });
    if (!resp.ok) return { error: `HTTP ${resp.status}` };
    const rows = ((await resp.json()).injuries?.injury ?? []) as Array<{
        id: string; status: string; details?: string; exp_return?: string;
    }>;
    const out = rows.flatMap(r => {
        const pid = resolve(r.id);
        if (!pid) return [];
        return [{
            player_id: pid,
            status: r.status,
            details: r.details ?? null,
            expected_return: parseExpReturn(r.exp_return ?? null),
            updated_at: new Date().toISOString(),
        }];
    });
    // Capture the previous snapshot so status changes can push to the
    // owners rostering the player (skipped when the table is empty — a
    // first run would otherwise notify for every injury in the league).
    const prev = new Map<string, string>();
    for (let from = 0; ; from += 1000) {
        const { data: page } = await supa.from("injuries")
            .select("player_id, status")
            .order("player_id")
            .range(from, from + 999);
        if (!page || page.length === 0) break;
        for (const r of page as Array<{ player_id: string; status: string }>) {
            prev.set(r.player_id, r.status);
        }
        if (page.length < 1000) break;
    }

    // Snapshot semantics: wipe then insert.
    await supa.from("injuries").delete().neq("player_id", "");
    if (out.length > 0) {
        const { error } = await supa.from("injuries").insert(out);
        if (error) throw new Error(`injuries insert: ${error.message}`);
    }

    if (prev.size > 0) {
        const changed = out.filter(r => prev.get(r.player_id) !== r.status);
        try {
            await notifyInjuryChanges(changed);
        } catch (err) {
            console.error(`injury push: ${err}`);   // never fail the sync over pushes
        }
    }
    // Also accumulate into injury_history at the current NFL week so future
    // simulations of *this* season have the same information environment.
    const week = currentNflWeek();
    if (week > 0 && out.length > 0) {
        const histRows = out.map(r => ({
            season: year, week, player_id: r.player_id,
            status: r.status, details: r.details,
            practice_status: null,
            expected_return: r.expected_return,
        }));
        await supa.from("injury_history").delete()
            .eq("season", year).eq("week", week);
        const { error } = await supa.from("injury_history")
            .upsert(histRows, { onConflict: "season,week,player_id" });
        if (error) console.error(`injury_history upsert: ${error.message}`);
    }
    return { received: rows.length, written: out.length, history_week: week };
}

// Queue a push (via the push_events outbox, drained by send_push) to every
// owner rostering a player whose injury status just changed, across active
// non-test leagues. One push per (owner, player) even when rostered in
// several leagues.
async function notifyInjuryChanges(
    changed: Array<{ player_id: string; status: string; details: string | null }>
) {
    if (changed.length === 0) return;
    // Cut-day style bulk swings are league news, not personal alerts — bail
    // rather than blast everyone.
    if (changed.length > 150) {
        console.error(`injury push: ${changed.length} changes, skipping as bulk`);
        return;
    }

    const names = new Map<string, string>();
    const ids = changed.map(c => c.player_id);
    for (let i = 0; i < ids.length; i += 200) {
        const { data } = await supa.from("players_cache")
            .select("id, name")
            .in("id", ids.slice(i, i + 200));
        for (const r of (data ?? []) as Array<{ id: string; name: string }>) {
            names.set(r.id, r.name);
        }
    }

    const events: Array<{ user_id: string; title: string; body: string; deep_link: string }> = [];
    const seen = new Set<string>();
    for (const c of changed) {
        const { data: teams } = await supa.from("teams")
            .select("owner_id, league_id, leagues!inner(is_test, season_completed)")
            .contains("roster", [c.player_id])
            .not("owner_id", "is", null)
            .eq("leagues.is_test", false)
            .eq("leagues.season_completed", false);
        for (const t of (teams ?? []) as Array<{ owner_id: string; league_id: string }>) {
            const key = `${t.owner_id}:${c.player_id}`;
            if (seen.has(key)) continue;
            seen.add(key);
            const name = names.get(c.player_id) ?? c.player_id;
            const detail = c.details ? ` (${c.details})` : "";
            events.push({
                user_id: t.owner_id,
                title: "Injury update",
                body: `${name} is now ${c.status}${detail}.`,
                deep_link: `tarsafantasy://league/${t.league_id}`,
            });
        }
    }
    for (let i = 0; i < events.length; i += 200) {
        const { error } = await supa.from("push_events").insert(events.slice(i, i + 200));
        if (error) console.error(`push_events insert: ${error.message}`);
    }
}

async function syncTrending(resolve: (id: string) => string | null) {
    const year = new Date().getUTCFullYear();
    const [addsResp, dropsResp] = await Promise.all([
        fetch(`${MFL_BASE}/${year}/export?TYPE=topAdds&JSON=1`,  { headers: { "User-Agent": USER_AGENT } }),
        fetch(`${MFL_BASE}/${year}/export?TYPE=topDrops&JSON=1`, { headers: { "User-Agent": USER_AGENT } }),
    ]);
    if (!addsResp.ok || !dropsResp.ok) return { error: `adds=${addsResp.status} drops=${dropsResp.status}` };
    const adds  = ((await addsResp.json()).topAdds?.player  ?? []) as Array<{ id: string; percent: string }>;
    const drops = ((await dropsResp.json()).topDrops?.player ?? []) as Array<{ id: string; percent: string }>;

    // Merge into a single map keyed by nflverse player_id.
    const merged = new Map<string, { adds_pct: number; drops_pct: number }>();
    for (const a of adds) {
        const pid = resolve(a.id); if (!pid) continue;
        merged.set(pid, { adds_pct: Number(a.percent) || 0, drops_pct: 0 });
    }
    for (const d of drops) {
        const pid = resolve(d.id); if (!pid) continue;
        const cur = merged.get(pid) ?? { adds_pct: 0, drops_pct: 0 };
        cur.drops_pct = Number(d.percent) || 0;
        merged.set(pid, cur);
    }
    const out = [...merged.entries()].map(([player_id, v]) => ({
        player_id, adds_pct: v.adds_pct, drops_pct: v.drops_pct,
        updated_at: new Date().toISOString(),
    }));

    await supa.from("trending_players").delete().neq("player_id", "");
    if (out.length > 0) {
        const { error } = await supa.from("trending_players").insert(out);
        if (error) throw new Error(`trending insert: ${error.message}`);
    }
    // Mirror into trending_history at the current NFL week so future sims
    // of this season see the same waiver-add signal we showed today.
    const week = currentNflWeek();
    if (week > 0 && out.length > 0) {
        const histRows = out.map(r => ({
            season: year, week, player_id: r.player_id,
            adds_pct: r.adds_pct, drops_pct: r.drops_pct,
        }));
        await supa.from("trending_history").delete()
            .eq("season", year).eq("week", week);
        const { error } = await supa.from("trending_history")
            .upsert(histRows, { onConflict: "season,week,player_id" });
        if (error) console.error(`trending_history upsert: ${error.message}`);
    }
    return { adds_received: adds.length, drops_received: drops.length, written: out.length, history_week: week };
}

async function syncAdp(season: number, scoring: "ppr"|"standard"|"half", resolve: (id: string) => string | null) {
    const isPpr = scoring === "ppr" ? "1" : scoring === "standard" ? "0" : "-1";  // MFL: 1=PPR, 0=std, -1=half
    const url = `${MFL_BASE}/${season}/export?TYPE=adp&FCOUNT=12&IS_PPR=${isPpr}&IS_KEEPER=N&JSON=1`;
    const resp = await fetch(url, { headers: { "User-Agent": USER_AGENT } });
    if (!resp.ok) return { error: `HTTP ${resp.status}` };
    const rows = ((await resp.json()).adp?.player ?? []) as Array<{
        id: string; averagePick: string; draftsSelectedIn?: string;
        minPick?: string; maxPick?: string;
    }>;
    // Snapshot date: for the current calendar year we use today; for any
    // backfilled prior season the data MFL returns is end-of-season, so we
    // anchor it to Aug 25 of that season (~typical draft week).
    const today = new Date();
    const thisYear = today.getUTCFullYear();
    const snapshotDate = season === thisYear
        ? today.toISOString().slice(0, 10)
        : `${season}-08-25`;
    const out = rows.flatMap(r => {
        const pid = resolve(r.id); if (!pid) return [];
        return [{
            season, scoring, player_id: pid,
            snapshot_date: snapshotDate,
            adp: Number(r.averagePick),
            times_drafted: r.draftsSelectedIn ? Number(r.draftsSelectedIn) : null,
            high: r.minPick ? Math.round(Number(r.minPick)) : null,
            low:  r.maxPick ? Math.round(Number(r.maxPick)) : null,
            stdev: null,  // MFL doesn't expose stdev
        }];
    });
    if (out.length === 0) return { received: rows.length, written: 0 };
    const { error } = await supa.from("adp")
        .upsert(out, { onConflict: "season,scoring,snapshot_date,player_id" });
    if (error) throw new Error(`adp upsert ${season}/${scoring}: ${error.message}`);
    return { received: rows.length, written: out.length, snapshot_date: snapshotDate };
}

// Pull every week of the season's nflSchedule. Upsert game spreads into
// nfl_schedules (fabricating nflverse-style game_ids so a later nflverse
// sync merges cleanly), and overwrite per-team ranks in nfl_team_ranks.
// Ranks are cumulative-current, so the last week with data wins.
async function syncSchedule(season: number) {
    let gamesSeen = 0, weeksWithData = 0;
    const ranks = new Map<string, { passOff: number|null; rushOff: number|null;
                                    passDef: number|null; rushDef: number|null }>();
    const gameRows: Array<{
        game_id: string; season: number; week: number;
        home_team: string; away_team: string;
        kickoff: string | null; home_spread: number | null; status: string;
    }> = [];

    for (let w = 1; w <= 18; w++) {
        const resp = await fetch(`${MFL_BASE}/${season}/export?TYPE=nflSchedule&W=${w}&JSON=1`,
                                 { headers: { "User-Agent": USER_AGENT } });
        if (!resp.ok) continue;
        const payload = await resp.json();
        const matchups = (payload.nflSchedule?.matchup ?? []) as Array<{
            kickoff?: string;
            team: Array<{ id: string; isHome: string; spread?: string;
                          passOffenseRank?: string; rushOffenseRank?: string;
                          passDefenseRank?: string; rushDefenseRank?: string; }>;
        }>;
        if (matchups.length === 0) continue;
        weeksWithData += 1;
        for (const m of matchups) {
            gamesSeen += 1;
            const home = m.team?.find(t => t.isHome === "1");
            const away = m.team?.find(t => t.isHome === "0");
            if (!home || !away) continue;
            const homeTeam = TEAM_ALIAS[home.id?.toUpperCase()] ?? home.id?.toUpperCase();
            const awayTeam = TEAM_ALIAS[away.id?.toUpperCase()] ?? away.id?.toUpperCase();
            // Fabricate the nflverse-style game_id so later sync_schedules
            // upserts collide and merge instead of duplicating the row.
            const weekStr = String(w).padStart(2, "0");
            const gameID  = `${season}_${weekStr}_${awayTeam}_${homeTeam}`;
            const kickoffISO = m.kickoff && m.kickoff !== ""
                ? new Date(Number(m.kickoff) * 1000).toISOString() : null;
            const spread = home.spread && home.spread !== "" ? Number(home.spread) : null;
            gameRows.push({
                game_id: gameID, season, week: w,
                home_team: homeTeam, away_team: awayTeam,
                kickoff: kickoffISO, home_spread: spread,
                status: "scheduled",
            });
            // Capture latest ranks (overwritten across weeks — last week wins).
            for (const t of [home, away]) {
                const team = TEAM_ALIAS[t.id?.toUpperCase()] ?? t.id?.toUpperCase();
                if (!team) continue;
                ranks.set(team, {
                    passOff: parseIntOrNull(t.passOffenseRank),
                    rushOff: parseIntOrNull(t.rushOffenseRank),
                    passDef: parseIntOrNull(t.passDefenseRank),
                    rushDef: parseIntOrNull(t.rushDefenseRank),
                });
            }
        }
    }

    // Two-pass write: UPDATE existing rows (only the home_spread column —
    // don't trample nflverse-owned kickoff/scores/status) and INSERT stubs
    // for game_ids that don't exist yet (off-season before nflverse publishes).
    let spreadsWritten = 0, stubsInserted = 0;
    const ids = gameRows.map(g => g.game_id);
    let existing = new Set<string>();
    if (ids.length > 0) {
        const { data } = await supa.from("nfl_schedules")
            .select("game_id").in("game_id", ids);
        existing = new Set((data ?? []).map((r: { game_id: string }) => r.game_id));
    }
    for (const g of gameRows) {
        if (existing.has(g.game_id)) {
            if (g.home_spread != null) {
                const { error } = await supa.from("nfl_schedules")
                    .update({ home_spread: g.home_spread })
                    .eq("game_id", g.game_id);
                if (!error) spreadsWritten += 1;
            }
        } else {
            const { error } = await supa.from("nfl_schedules").insert(g);
            if (!error) {
                stubsInserted += 1;
                if (g.home_spread != null) spreadsWritten += 1;
            }
        }
    }

    // Write team ranks if any meaningful values present.
    const rows = [...ranks.entries()]
        .filter(([_, r]) => r.passOff != null || r.rushOff != null || r.passDef != null || r.rushDef != null)
        .map(([team, r]) => ({
            team,
            pass_offense: r.passOff, rush_offense: r.rushOff,
            pass_defense: r.passDef, rush_defense: r.rushDef,
            updated_at: new Date().toISOString(),
        }));
    if (rows.length > 0) {
        const { error } = await supa.from("nfl_team_ranks")
            .upsert(rows, { onConflict: "team" });
        if (error) throw new Error(`team_ranks upsert: ${error.message}`);
    }
    return { weeksWithData, gamesSeen, stubsInserted, spreadsWritten, ranksWritten: rows.length };
}

async function syncMostStarted(resolve: (id: string) => string | null) {
    const resp = await fetch(`${MFL_BASE}/${new Date().getUTCFullYear()}/export?TYPE=topStarters&JSON=1`,
                             { headers: { "User-Agent": USER_AGENT } });
    if (!resp.ok) return { error: `HTTP ${resp.status}` };
    const rows = ((await resp.json()).topStarters?.player ?? []) as Array<{ id: string; percent: string }>;
    const out = rows.flatMap(r => {
        const pid = resolve(r.id); if (!pid) return [];
        return [{ player_id: pid, started_pct: Number(r.percent) || 0,
                  updated_at: new Date().toISOString() }];
    });
    await supa.from("most_started").delete().neq("player_id", "");
    if (out.length > 0) {
        const { error } = await supa.from("most_started").insert(out);
        if (error) throw new Error(`most_started insert: ${error.message}`);
    }
    // Mirror into most_started_history at the current NFL week.
    const year = new Date().getUTCFullYear();
    const week = currentNflWeek();
    if (week > 0 && out.length > 0) {
        const histRows = out.map(r => ({
            season: year, week, player_id: r.player_id,
            started_pct: r.started_pct,
        }));
        await supa.from("most_started_history").delete()
            .eq("season", year).eq("week", week);
        const { error } = await supa.from("most_started_history")
            .upsert(histRows, { onConflict: "season,week,player_id" });
        if (error) console.error(`most_started_history upsert: ${error.message}`);
    }
    return { received: rows.length, written: out.length, history_week: week };
}

// Approximate current NFL regular-season week (1..18). Returns 0 outside
// the season window. Week 1 starts the Thursday after Labor Day; this
// rough approximation (Sep 5 anchor + 7-day weeks) is close enough for
// labeling the trending_history snapshot.
function currentNflWeek(): number {
    const now = new Date();
    const year = now.getUTCFullYear();
    const seasonStart = new Date(Date.UTC(year, 8, 5));  // Sep 5
    if (now < seasonStart) return 0;
    const days = Math.floor((now.getTime() - seasonStart.getTime()) / (24 * 3600 * 1000));
    const week = Math.floor(days / 7) + 1;
    return week >= 1 && week <= 18 ? week : 0;
}

function parseIntOrNull(s: string | undefined): number | null {
    if (!s) return null;
    const n = parseInt(s, 10);
    return Number.isFinite(n) ? n : null;
}

// "Last, First" or "Last, First M." → "First Last".
function mflToFirstLast(name: string): string {
    if (!name.includes(",")) return name;
    const [last, first] = name.split(",", 2).map(s => s.trim());
    return `${first} ${last}`;
}

function normalizeName(name: string): string {
    return name
        .toLowerCase()
        .replace(/\./g, "")
        .replace(/'/g, "")
        .replace(/\s+(jr|sr|iii|ii|iv|v)\b/g, "")
        .replace(/\s+/g, " ")
        .trim();
}

// MFL exp_return is e.g. "Aug 1, 2026" or empty. Returns ISO date string or null.
function parseExpReturn(s: string | null): string | null {
    if (!s) return null;
    const t = s.trim();
    if (!t) return null;
    const d = new Date(t);
    if (isNaN(d.getTime())) return null;
    return d.toISOString().slice(0, 10);
}
