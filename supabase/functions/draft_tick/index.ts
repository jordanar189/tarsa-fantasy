// Per-minute cron that advances any live draft whose pick clock has expired.
// Picks the strategy-driven best-available player for the team on the clock
// (using the same loop logic the client uses) and calls public.make_pick(
// ... p_is_auto := true).
//
// This is a backstop — connected clients also call autoPickIfExpired the
// instant their local timer hits zero. The RPC's row-level lock ensures
// duplicate auto-picks for the same pick number are rejected by the unique
// constraint on (draft_id, pick_number).

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

interface DraftRow {
    id: string; league_id: string; format: string; status: string;
    pick_seconds: number; current_pick: number; total_picks: number;
    pick_deadline: string | null; pick_order: string[];
    pick_owner_overrides?: Record<string, string> | null;
    pool?: string | null;   // 'all' | 'rookies'
}
interface RosterConfigRow {
    qb?: number; rb?: number; wr?: number; te?: number;
    flex?: number; superflex?: number; wrFlex?: number; recFlex?: number;
    k?: number; def?: number; bench?: number;
    dl?: number; lb?: number; db?: number; idpFlex?: number;
}
interface LeagueRow {
    id: string; season: number; scoring: string; is_test: boolean;
    roster_config: RosterConfigRow | null;
}
interface PickRow { team_id: string; player_id: string; pick_number: number; }
interface TeamKeepersRow { id: string; keepers: string[] | null; }
interface PlayerStat { player_id: string; fantasy_points_ppr: number; }
interface CachePlayer {
    id: string; position: string;
    years_exp?: number | null; draft_year?: number | null;
}
interface AdpRow { player_id: string; adp: number; snapshot_date: string; }

// ============================================================
// Auto-pick strategy (mirror of Fantasy.bestAutoPickPlayerID).
// Mid-round loop of 7 with position template + per-loop budgets.
// The final (k + def) rounds are the K/DEF phase — sized by the
// league's actual starter slots, absent entirely when it rosters
// neither, and only asking for the positions still missing.
// ============================================================
const LOOP_ROUNDS    = 7;
const BUDGET_RB      = 2;
const BUDGET_WR      = 2;
const BUDGET_TE      = 1;
const BUDGET_QB      = 1;
const BUDGET_FLEX    = 1;

function roundTemplate(loopOffset: number): Set<string> {
    if (loopOffset === 0 || loopOffset === 1) return new Set(["RB","WR","TE"]);
    if (loopOffset === 2 || loopOffset === 3 || loopOffset === 4) return new Set(["RB","WR","TE","QB"]);
    return new Set(["RB","WR","TE"]);
}

// Specific defender positions → IDP lineup group. Mirrors Models.swift's
// idpGroup(of:) — IDP slot eligibility and the specialist draft phase both
// match by group, since cache positions are specific (DE, ILB, FS, …).
function idpGroup(position: string): string | null {
    switch (position.toUpperCase()) {
        case "DL": case "DE": case "DT": case "NT": case "EDGE": return "DL";
        case "LB": case "ILB": case "OLB": case "MLB":           return "LB";
        case "DB": case "CB": case "S": case "FS": case "SS": case "SAF": return "DB";
        default: return null;
    }
}

function allowedPositions(
    round: number, totalRounds: number, loopPicks: string[],
    kSlots: number, defSlots: number, kOwned: number, defOwned: number,
    qbBudget: number,
    idpSlots = 0, idpNeeds: Set<string> = new Set(),
): Set<string> {
    const kdefReserve = kSlots + defSlots + idpSlots;
    if (kdefReserve > 0 && round > totalRounds - kdefReserve) {
        const need = new Set<string>();
        if (kOwned < kSlots) need.add("K");
        if (defOwned < defSlots) need.add("DEF");
        for (const g of idpNeeds) need.add(g);
        if (need.size > 0) return need;
        // Specialists already covered — fall through to the normal template.
    }
    const loopOffset = (round - 1) % LOOP_ROUNDS;
    const template = roundTemplate(loopOffset);
    const counts = new Map<string, number>();
    for (const p of loopPicks) counts.set(p, (counts.get(p) ?? 0) + 1);
    const rbOver = Math.max(0, (counts.get("RB") ?? 0) - BUDGET_RB);
    const wrOver = Math.max(0, (counts.get("WR") ?? 0) - BUDGET_WR);
    const teOver = Math.max(0, (counts.get("TE") ?? 0) - BUDGET_TE);
    const flexLeft = Math.max(0, BUDGET_FLEX - (rbOver + wrOver + teOver));
    const hasCapacity = (pos: string): boolean => {
        switch (pos) {
            case "RB": return (counts.get("RB") ?? 0) < BUDGET_RB || flexLeft > 0;
            case "WR": return (counts.get("WR") ?? 0) < BUDGET_WR || flexLeft > 0;
            case "TE": return (counts.get("TE") ?? 0) < BUDGET_TE || flexLeft > 0;
            case "QB": return (counts.get("QB") ?? 0) < qbBudget;
            default:   return true;
        }
    };
    return new Set([...template].filter(hasCapacity));
}

// Picks in the same loop as `round` for `teamID`, excluding K-phase picks
// (the final `kdefReserve` rounds).
function positionsInCurrentLoop(
    teamPicks: { pick_number: number; position: string }[],
    round: number, totalRounds: number, kdefReserve: number,
): string[] {
    const kPhaseStart = totalRounds - kdefReserve + 1;
    if (kdefReserve > 0 && round >= kPhaseStart) return [];
    const upcomingLoop = Math.floor((round - 1) / LOOP_ROUNDS);
    // Convert each pick to a round number for *this team*. With snake/linear
    // draft, the team's pick rounds are 1-indexed sequentially — pick #1 for
    // the team is its round 1, pick #2 is round 2, etc.
    const sorted = [...teamPicks].sort((a, b) => a.pick_number - b.pick_number);
    return sorted
        .map((p, i) => ({ round: i + 1, position: p.position }))
        .filter(p => {
            if (kdefReserve > 0 && p.round >= kPhaseStart) return false;
            return Math.floor((p.round - 1) / LOOP_ROUNDS) === upcomingLoop;
        })
        .map(p => p.position);
}

Deno.serve(async (_req: Request) => {
    try {
        const now = new Date();
        const { data: drafts } = await supa.from("drafts")
            .select("*").eq("status", "live");
        const results: { draft: string; outcome: string }[] = [];
        for (const d of (drafts ?? []) as DraftRow[]) {
            if (d.format === "auction") {
                // Auction clocks live partly on the open lot, so the
                // pick_deadline prefilter doesn't apply.
                const r = await advanceAuction(d, now);
                if (r !== "waiting") results.push({ draft: d.id, outcome: r });
                continue;
            }
            if (!d.pick_deadline || new Date(d.pick_deadline).getTime() > now.getTime()) {
                continue;
            }
            const r = await advanceDraft(d);
            results.push({ draft: d.id, outcome: r });
        }
        return new Response(JSON.stringify({
            processed: results.length, results,
        }), { headers: { "Content-Type": "application/json" } });
    } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

interface LotRow {
    id: string; player_id: string; bid_deadline: string | null; status: string;
}

// Auction backstop: settle the open lot once its bid clock has expired, or
// auto-nominate the best available player at $1 when the nomination clock
// has expired with no lot open. Connected clients do both faster; every
// path here is idempotent/deadline-gated server-side.
async function advanceAuction(d: DraftRow, now: Date): Promise<string> {
    const { data: lots } = await supa.from("auction_lots")
        .select("id, player_id, bid_deadline, status")
        .eq("draft_id", d.id).eq("status", "open").limit(1);
    const lot = (lots ?? [])[0] as LotRow | undefined;

    if (lot) {
        if (lot.bid_deadline && new Date(lot.bid_deadline).getTime() <= now.getTime()) {
            const { error } = await supa.rpc("settle_lot", { p_draft_id: d.id });
            return error ? `settle error: ${error.message}` : "settled";
        }
        return "waiting";
    }

    if (!d.pick_deadline || new Date(d.pick_deadline).getTime() > now.getTime()) {
        return "waiting";
    }

    // Nomination clock expired: nominate best available by ADP for the team
    // on the nomination clock (round-robin over pick_order).
    const teamCount = d.pick_order.length;
    if (teamCount === 0) return "no_pick_order";
    const teamID = d.pick_order[(d.current_pick - 1) % teamCount];

    const { data: lg } = await supa.from("leagues")
        .select("id, season, scoring, is_test, roster_config")
        .eq("id", d.league_id).single();
    if (!lg) return "no_league";

    // Unavailable = every rostered player in the league (covers keepers and
    // settled lots, whose winners get the player appended) plus any player
    // already auctioned in this draft.
    const { data: teamRows } = await supa.from("teams")
        .select("id, roster").eq("league_id", d.league_id);
    const taken = new Set<string>(
        ((teamRows ?? []) as { id: string; roster: string[] | null }[])
            .flatMap(t => t.roster ?? [])
    );
    const { data: lotRows } = await supa.from("auction_lots")
        .select("player_id").eq("draft_id", d.id);
    for (const r of (lotRows ?? []) as { player_id: string }[]) taken.add(r.player_id);

    const adpByID = await fetchAdpRankings(lg as LeagueRow);
    const cache: CachePlayer[] = [];
    for (let from = 0; ; from += 1000) {
        const { data: page } = await supa.from("players_cache")
            .select("id, position")
            .order("id")
            .range(from, from + 999);
        if (!page || page.length === 0) break;
        cache.push(...(page as CachePlayer[]));
        if (page.length < 1000) break;
    }
    // Prefer ADP-ranked candidates; without a snapshot, fall back to season
    // fantasy points (same tiebreak advanceDraft uses) so the nomination is
    // still a sensible best-available rather than alphabetical-by-id.
    let available = cache.filter(p => !taken.has(p.id) && adpByID.has(p.id));
    if (available.length > 0) {
        available.sort((a, b) => (adpByID.get(a.id) ?? 9999) - (adpByID.get(b.id) ?? 9999));
    } else {
        available = cache.filter(p => !taken.has(p.id));
        if (available.length === 0) return "no_candidates";
        const totals = new Map<string, number>();
        for (let from = 0; ; from += 1000) {
            const { data: page } = await supa.from("player_games")
                .select("player_id, fantasy_points_ppr")
                .eq("season", (lg as LeagueRow).season)
                .order("player_id")
                .order("week")
                .range(from, from + 999);
            if (!page || page.length === 0) break;
            for (const s of page as PlayerStat[]) {
                totals.set(s.player_id, (totals.get(s.player_id) ?? 0) + Number(s.fantasy_points_ppr));
            }
            if (page.length < 1000) break;
        }
        available.sort((a, b) => (totals.get(b.id) ?? 0) - (totals.get(a.id) ?? 0));
    }

    const { error } = await supa.rpc("nominate_player", {
        p_draft_id: d.id, p_team_id: teamID,
        p_player_id: available[0].id, p_amount: 1, p_is_auto: true,
    });
    return error ? `nominate error: ${error.message}` : "nominated";
}

async function advanceDraft(d: DraftRow): Promise<string> {
    // Which team is on the clock? Traded picks override the snake math via
    // the map start_draft materialized (mirrors public.team_on_clock).
    const teamCount = d.pick_order.length;
    if (teamCount === 0) return "no_pick_order";
    const roundIdx    = Math.floor((d.current_pick - 1) / teamCount);
    let   posInRound  = (d.current_pick - 1) % teamCount;
    if (d.format === "snake" && roundIdx % 2 === 1) {
        posInRound = teamCount - 1 - posInRound;
    }
    const overrides = d.pick_owner_overrides ?? {};
    const teamID = overrides[String(d.current_pick)] ?? d.pick_order[posInRound];
    if (!teamID) return "no_team";

    // League + roster config (drive total rounds + K-phase logic).
    const { data: lg } = await supa.from("leagues")
        .select("id, season, scoring, is_test, roster_config")
        .eq("id", d.league_id).single();
    if (!lg) return "no_league";
    const L = lg as LeagueRow;
    const rc = L.roster_config ?? {};
    // Mirror RosterConfig.totalSize: every starter slot (incl. def and the
    // flex variants) + bench. Older leagues' jsonb may lack the newer keys.
    const kSlots    = rc.k ?? 1;
    const defSlots  = rc.def ?? 1;
    const superflex = rc.superflex ?? 0;
    const dlSlots   = rc.dl ?? 0;
    const lbSlots   = rc.lb ?? 0;
    const dbSlots   = rc.db ?? 0;
    const idpFlexSlots = rc.idpFlex ?? 0;
    const idpSlots  = dlSlots + lbSlots + dbSlots + idpFlexSlots;
    const totalRounds =
        (rc.qb ?? 1) + (rc.rb ?? 2) + (rc.wr ?? 2) + (rc.te ?? 1) +
        (rc.flex ?? 1) + superflex + (rc.wrFlex ?? 0) + (rc.recFlex ?? 0) +
        kSlots + defSlots + idpSlots + (rc.bench ?? 6);

    // Keeper-lite: kept players never enter the pool, and a team's own
    // keepers count as its earliest "picks" so the round/position math
    // (mirroring the client's roster.count + 1) tracks the full roster
    // size even though the draft itself runs keeper_count fewer rounds.
    const { data: teamRows } = await supa.from("teams")
        .select("id, keepers").eq("league_id", d.league_id);
    const keepersByTeam = new Map<string, string[]>(
        ((teamRows ?? []) as TeamKeepersRow[]).map(t => [t.id, t.keepers ?? []])
    );
    const allKeepers = [...keepersByTeam.values()].flat();
    const myKeepers = keepersByTeam.get(teamID) ?? [];

    // What's already been picked across all teams (plus every keeper).
    const { data: pickedRows } = await supa.from("draft_picks")
        .select("player_id, team_id, pick_number").eq("draft_id", d.id);
    const allPicks = (pickedRows ?? []) as PickRow[];
    const pickedIDs = new Set([...allPicks.map(p => p.player_id), ...allKeepers]);

    // Round-cost leagues pre-fill keepers as real draft_picks rows, so only
    // count the ones NOT already among the team's picks (keeper-lite).
    const myPicks = allPicks.filter(p => p.team_id === teamID);
    const pickedByMe = new Set(myPicks.map(p => p.player_id));
    const pendingKeepers = myKeepers.filter(k => !pickedByMe.has(k));

    // The team's roster round: keepers + picks so far + 1. Equals the
    // draft round (roundIdx + 1) in leagues without keepers.
    const round = pendingKeepers.length + myPicks.length + 1;

    // Player positions for the team's keepers + picks. Keepers sort first
    // (synthetic pick numbers below any real pick).
    const myIds = [...pendingKeepers, ...myPicks.map(p => p.player_id)];
    let myPickRows: { pick_number: number; position: string }[] = [];
    if (myIds.length > 0) {
        const { data: rows } = await supa.from("players_cache")
            .select("id, position")
            .in("id", myIds);
        const posByID = new Map<string, string>(
            ((rows ?? []) as CachePlayer[]).map(r => [r.id, (r.position ?? "").toUpperCase()])
        );
        myPickRows = [
            ...pendingKeepers.map((pid, i) => ({
                pick_number: -1000 + i,
                position: posByID.get(pid) ?? "",
            })),
            ...myPicks.map(p => ({
                pick_number: p.pick_number,
                position: posByID.get(p.player_id) ?? "",
            })),
        ];
    }
    const loopPicks = positionsInCurrentLoop(myPickRows, round, totalRounds, kSlots + defSlots + idpSlots);
    const kOwned   = myPickRows.filter(p => p.position === "K").length;
    const defOwned = myPickRows.filter(p => p.position === "DEF").length;
    // IDP groups the specialist phase should still chase: dedicated slots
    // first, then the IDP flex once dedicated overflow hasn't consumed it.
    const dlOwned = myPickRows.filter(p => idpGroup(p.position) === "DL").length;
    const lbOwned = myPickRows.filter(p => idpGroup(p.position) === "LB").length;
    const dbOwned = myPickRows.filter(p => idpGroup(p.position) === "DB").length;
    const idpNeeds = new Set<string>();
    if (dlOwned < dlSlots) idpNeeds.add("DL");
    if (lbOwned < lbSlots) idpNeeds.add("LB");
    if (dbOwned < dbSlots) idpNeeds.add("DB");
    const idpFlexUsed = Math.max(0, dlOwned - dlSlots)
        + Math.max(0, lbOwned - lbSlots)
        + Math.max(0, dbOwned - dbSlots);
    if (idpFlexSlots > idpFlexUsed) { idpNeeds.add("DL"); idpNeeds.add("LB"); idpNeeds.add("DB"); }
    const allowed = allowedPositions(
        round, totalRounds, loopPicks,
        kSlots, defSlots, kOwned, defOwned,
        Math.max(BUDGET_QB, (rc.qb ?? 1) + superflex),
        idpSlots, idpNeeds,
    );

    // Build the ADP-ranked candidate list. Pick the right snapshot:
    // sim leagues use the latest snapshot <= the season's draft anchor
    // (Aug 25 of the season); real leagues use the most recent overall.
    const adpByID = await fetchAdpRankings(L);

    // Player metadata (position) for every candidate we might rank.
    // Paginated: PostgREST caps unranged selects at 1000 rows, and
    // players_cache holds every NFL player — an unpaginated fetch made the
    // auto-pick pool an arbitrary 1000-row subset.
    const cache: CachePlayer[] = [];
    for (let from = 0; ; from += 1000) {
        const { data: page } = await supa.from("players_cache")
            .select("id, position, years_exp, draft_year")
            .order("id")
            .range(from, from + 999);
        if (!page || page.length === 0) break;
        cache.push(...(page as CachePlayer[]));
        if (page.length < 1000) break;
    }

    // Available = not-yet-picked, restricted to the incoming class for
    // rookie drafts (mirrors public.is_rookie).
    const isRookie = (p: CachePlayer) =>
        p.years_exp === 0 || (p.years_exp == null && p.draft_year === L.season);
    const available = cache.filter(p =>
        !pickedIDs.has(p.id) && (d.pool !== "rookies" || isRookie(p))
    );
    if (available.length === 0) return "no_candidates";

    // Season-points fallback for tiebreaking players without ADP.
    // Paginated for the same 1000-row reason as above.
    const totals = new Map<string, number>();
    for (let from = 0; ; from += 1000) {
        // Ordered by the full (player_id, week) key: player_id repeats
        // across weeks, and range pagination over a non-unique order can
        // skip or double-count rows at page boundaries.
        const { data: page } = await supa.from("player_games")
            .select("player_id, fantasy_points_ppr")
            .eq("season", L.season)
            .order("player_id")
            .order("week")
            .range(from, from + 999);
        if (!page || page.length === 0) break;
        for (const s of page as PlayerStat[]) {
            totals.set(s.player_id, (totals.get(s.player_id) ?? 0) + Number(s.fantasy_points_ppr));
        }
        if (page.length < 1000) break;
    }

    // Sort: ADP asc; players without ADP fall to bottom ordered by points desc.
    available.sort((a, b) => {
        const aa = adpByID.get(a.id);
        const bb = adpByID.get(b.id);
        if (aa != null && bb != null) return aa - bb;
        if (aa != null) return -1;
        if (bb != null) return 1;
        return (totals.get(b.id) ?? 0) - (totals.get(a.id) ?? 0);
    });

    // First match within the allowed pool; fallback = overall best ADP.
    // IDP entries in `allowed` are group tokens (DL/LB/DB) — match either way.
    const allowedPick = available.find(p => {
        const pos = (p.position ?? "").toUpperCase();
        return allowed.has(pos) || allowed.has(idpGroup(pos) ?? "#");
    });
    const choice = allowedPick ?? available[0];
    return await invokeMakePick(d.id, teamID, choice.id);
}

async function fetchAdpRankings(L: LeagueRow): Promise<Map<string, number>> {
    const scoring = (L.scoring ?? "ppr").toLowerCase();
    // For sims, anchor to the season's draft window (late August).
    const anchor = L.is_test
        ? `${L.season}-08-25`
        : new Date().toISOString().slice(0, 10);

    // Find the latest snapshot_date <= anchor for this (season, scoring).
    const { data: snapRow } = await supa.from("adp")
        .select("snapshot_date")
        .eq("season", L.season).eq("scoring", scoring)
        .lte("snapshot_date", anchor)
        .order("snapshot_date", { ascending: false })
        .limit(1).maybeSingle();
    const snapshot = (snapRow as { snapshot_date: string } | null)?.snapshot_date;
    if (!snapshot) return new Map();

    const { data: rows } = await supa.from("adp")
        .select("player_id, adp, snapshot_date")
        .eq("season", L.season).eq("scoring", scoring)
        .eq("snapshot_date", snapshot);
    const out = new Map<string, number>();
    for (const r of (rows ?? []) as AdpRow[]) {
        out.set(r.player_id, Number(r.adp));
    }
    return out;
}

async function invokeMakePick(draftID: string, teamID: string, playerID: string): Promise<string> {
    const { error } = await supa.rpc("make_pick", {
        p_draft_id: draftID, p_team_id: teamID,
        p_player_id: playerID, p_is_auto: true,
    });
    if (error) return `error: ${error.message}`;
    // A timeout pick also locks the team into auto-pick mode for the rest
    // of the draft. They can manually toggle it back off from the room.
    const { error: autoErr } = await supa.rpc("set_auto_pick", {
        p_draft_id: draftID, p_team_id: teamID, p_enabled: true,
    });
    if (autoErr) return `picked (auto-lock failed: ${autoErr.message})`;
    return "picked";
}
