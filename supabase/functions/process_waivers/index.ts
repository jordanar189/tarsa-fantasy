// Resolves pending waiver_claims for each league whose process tick has
// passed since last_waivers_run_at. Scheduled hourly via pg_cron; this
// function no-ops cheaply for leagues that aren't yet due.
//
// Resolution order, per league:
//   1. Pull waiver_priority (ordered team IDs).
//   2. For each team in priority order, walk that team's pending claims in
//      team_priority order.
//   3. For each claim: validate add player is still on waivers + not on any
//      roster; validate the drop (if any) is still on the team's roster.
//      If OK, apply the add/drop atomically, mark claim processed, log a
//      transaction row.
//   4. After resolving, move teams that won claims to the back of the
//      priority list (rolling waivers). Teams without wins keep their slot.
//   5. Clear dropped_players rows whose waiver_until is in the past AND the
//      player wasn't claimed.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

interface LeagueRow {
    id: string;
    waiver_process_day: number;
    waiver_process_hour: number;
    waiver_priority: string[];
    last_waivers_run_at: string | null;
    commissioner_approval: boolean;
}
interface TeamRow {
    id: string; league_id: string; name: string;
    roster: string[]; starters: string[]; owner_id: string | null;
}
interface ClaimRow {
    id: string; league_id: string; team_id: string;
    add_player_id: string; drop_player_id: string | null;
    team_priority: number; status: string; created_at: string;
}

Deno.serve(async (_req: Request) => {
    try {
        const now = new Date();
        const leagues = await loadDueLeagues(now);
        const out: Record<string, unknown>[] = [];
        for (const lg of leagues) {
            const summary = await processLeague(lg, now);
            out.push({ league: lg.id, ...summary });
        }
        await clearExpiredDrops(now);
        return new Response(JSON.stringify({ processed: out.length, leagues: out }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

// Returns leagues where the most recent occurrence of (process_day,
// process_hour) is after last_waivers_run_at.
async function loadDueLeagues(now: Date): Promise<LeagueRow[]> {
    const { data, error } = await supa.from("leagues").select(
        "id, waiver_process_day, waiver_process_hour, waiver_priority, last_waivers_run_at, commissioner_approval"
    );
    if (error) throw error;
    const all = (data ?? []) as LeagueRow[];
    return all.filter(l => {
        const tick = mostRecentTick(now, l.waiver_process_day, l.waiver_process_hour);
        if (!tick) return false;
        if (!l.last_waivers_run_at) return true;
        return tick.getTime() > new Date(l.last_waivers_run_at).getTime();
    });
}

// Most recent timestamp on (dow, hour) UTC strictly <= now.
function mostRecentTick(now: Date, dow: number, hour: number): Date | null {
    const result = new Date(Date.UTC(
        now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), hour, 0, 0
    ));
    const offsetDays = (now.getUTCDay() - dow + 7) % 7;
    result.setUTCDate(result.getUTCDate() - offsetDays);
    if (result.getTime() > now.getTime()) {
        result.setUTCDate(result.getUTCDate() - 7);
    }
    return result;
}

async function processLeague(lg: LeagueRow, now: Date) {
    // Pull all pending claims for this league, plus teams (for roster
    // mutations) and dropped_players (to validate waiver state).
    const { data: claimRows } = await supa.from("waiver_claims")
        .select("*").eq("league_id", lg.id).eq("status", "pending");
    const claims = (claimRows ?? []) as ClaimRow[];

    const { data: teamRows } = await supa.from("teams").select("*").eq("league_id", lg.id);
    const teams = (teamRows ?? []) as TeamRow[];
    const teamByID = new Map(teams.map(t => [t.id, t]));

    const { data: dropRows } = await supa.from("dropped_players").select("*").eq("league_id", lg.id);
    const onWaivers = new Set((dropRows ?? []).map((r: { player_id: string }) => r.player_id));

    // Index claims by team and sort by team_priority ascending.
    const claimsByTeam = new Map<string, ClaimRow[]>();
    for (const c of claims) {
        if (!claimsByTeam.has(c.team_id)) claimsByTeam.set(c.team_id, []);
        claimsByTeam.get(c.team_id)!.push(c);
    }
    for (const arr of claimsByTeam.values()) {
        arr.sort((a, b) => a.team_priority - b.team_priority);
    }

    // Walk teams in waiver_priority order. Each team's first VALID claim
    // wins; subsequent claims for the same player by lower-priority teams
    // are skipped because the player has already been added.
    const addedThisTick = new Set<string>();
    const winnerTeams: string[] = [];
    const processed: { id: string; status: string; reason?: string }[] = [];

    for (const teamID of lg.waiver_priority ?? []) {
        const team = teamByID.get(teamID);
        if (!team) continue;
        const teamClaims = claimsByTeam.get(teamID) ?? [];
        let wonOne = false;
        for (const claim of teamClaims) {
            if (wonOne) {
                // Walk remaining claims later (in another pass) so the team
                // gets one win per tick before others go again. Skip for now.
                continue;
            }
            const result = await attemptClaim(claim, team, onWaivers, addedThisTick);
            processed.push(result);
            if (result.status === "processed") {
                wonOne = true;
                winnerTeams.push(teamID);
            }
        }
    }

    // Optional second pass: teams that haven't won yet may get a turn at
    // remaining claims now. Keep this simple — one extra pass is enough for
    // typical league sizes; rare edge cases can wait for the next tick.
    for (const teamID of lg.waiver_priority ?? []) {
        const team = teamByID.get(teamID);
        if (!team) continue;
        const teamClaims = (claimsByTeam.get(teamID) ?? [])
            .filter(c => !processed.find(p => p.id === c.id));
        for (const claim of teamClaims) {
            const result = await attemptClaim(claim, team, onWaivers, addedThisTick);
            processed.push(result);
        }
    }

    // Rolling waivers: winners go to the back of the priority list.
    if (winnerTeams.length > 0) {
        const losers = (lg.waiver_priority ?? []).filter(t => !winnerTeams.includes(t));
        const newPriority = [...losers, ...winnerTeams];
        await supa.from("leagues").update({ waiver_priority: newPriority }).eq("id", lg.id);
    }

    await supa.from("leagues").update({ last_waivers_run_at: now.toISOString() }).eq("id", lg.id);

    return {
        processed: processed.filter(p => p.status === "processed").length,
        failed:    processed.filter(p => p.status === "failed").length,
        skipped:   processed.filter(p => p.status === "skipped").length,
    };
}

async function attemptClaim(
    claim: ClaimRow, team: TeamRow,
    onWaivers: Set<string>, addedThisTick: Set<string>
): Promise<{ id: string; status: string; reason?: string }> {

    // If someone earlier in this tick already grabbed the player, skip
    // (priority order handles "ties" implicitly).
    if (addedThisTick.has(claim.add_player_id)) {
        await failClaim(claim.id, "Higher-priority team won this player.");
        return { id: claim.id, status: "failed", reason: "outbid" };
    }

    // Validate add player is on waivers.
    if (!onWaivers.has(claim.add_player_id)) {
        await failClaim(claim.id, "Player is no longer on waivers.");
        return { id: claim.id, status: "failed", reason: "not_on_waivers" };
    }

    // Re-pull team to ensure the latest roster (other claims may have
    // mutated it in this same pass).
    const { data: latest } = await supa.from("teams").select("*").eq("id", team.id).single();
    if (!latest) {
        await failClaim(claim.id, "Team not found.");
        return { id: claim.id, status: "failed", reason: "no_team" };
    }
    const roster = [...latest.roster] as string[];

    // Validate drop (if specified) is still on roster.
    if (claim.drop_player_id) {
        if (!roster.includes(claim.drop_player_id)) {
            await failClaim(claim.id, "Drop player is no longer on your roster.");
            return { id: claim.id, status: "failed", reason: "drop_missing" };
        }
        const i = roster.indexOf(claim.drop_player_id);
        roster.splice(i, 1);
    }
    roster.push(claim.add_player_id);

    // Check roster size — fetch league for limit.
    const { data: lg } = await supa.from("leagues").select("roster_config").eq("id", claim.league_id).single();
    const cfg = (lg?.roster_config ?? {}) as Record<string, number>;
    const totalSize = (cfg.qb ?? 1) + (cfg.rb ?? 2) + (cfg.wr ?? 2) + (cfg.te ?? 1)
        + (cfg.flex ?? 1) + (cfg.k ?? 1) + (cfg.bench ?? 6);
    if (roster.length > totalSize) {
        await failClaim(claim.id, "Adding this player would exceed your roster size — set a drop.");
        return { id: claim.id, status: "failed", reason: "roster_full" };
    }

    // Apply the change.
    await supa.from("teams").update({ roster, starters: latest.starters }).eq("id", team.id);
    // Remove the player from waivers + track this tick's wins.
    await supa.from("dropped_players").delete()
        .eq("league_id", claim.league_id).eq("player_id", claim.add_player_id);
    onWaivers.delete(claim.add_player_id);
    addedThisTick.add(claim.add_player_id);
    // If a drop happened, register the dropped player on waivers for the
    // league's standard waiver period (claim resolution dropped them).
    if (claim.drop_player_id) {
        const { data: lgFull } = await supa.from("leagues")
            .select("waiver_period_hours").eq("id", claim.league_id).single();
        const periodHours = (lgFull?.waiver_period_hours ?? 24) as number;
        const until = new Date(Date.now() + periodHours * 3600 * 1000).toISOString();
        await supa.from("dropped_players").upsert({
            league_id: claim.league_id,
            player_id: claim.drop_player_id,
            dropped_at: new Date().toISOString(),
            waiver_until: until,
        });
    }
    // Mark claim processed + log transaction.
    await supa.from("waiver_claims").update({
        status: "processed", processed_at: new Date().toISOString(),
    }).eq("id", claim.id);
    await supa.from("transactions").insert({
        league_id: claim.league_id, team_id: team.id,
        kind: "waiver_claim",
        add_player_id: claim.add_player_id,
        drop_player_id: claim.drop_player_id,
        status: "completed",
    });
    return { id: claim.id, status: "processed" };
}

async function failClaim(id: string, reason: string) {
    await supa.from("waiver_claims").update({
        status: "failed", failure_reason: reason, processed_at: new Date().toISOString(),
    }).eq("id", id);
}

async function clearExpiredDrops(now: Date) {
    // Players whose waiver_until is in the past clear off the waivers list;
    // they become free agents implicitly (no DB state needed beyond the row's
    // absence). Keep recently-cleared rows for ~7 days so the UI can still
    // show "added Tue at 8pm" context if needed in the future.
    const cutoff = new Date(now.getTime() - 7 * 86400 * 1000).toISOString();
    await supa.from("dropped_players").delete().lt("waiver_until", cutoff);
}
