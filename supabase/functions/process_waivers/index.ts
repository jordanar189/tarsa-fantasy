// Resolves pending waiver_claims for each league whose process tick has
// passed since last_waivers_run_at. Scheduled hourly via pg_cron; this
// function no-ops cheaply for leagues that aren't yet due.
//
// Two resolution modes (leagues.waiver_mode):
//
//   priority — repeated one-win-per-team rounds over the waiver_priority
//     order. Within a round each team attempts its claims in team_priority
//     order until one wins; a round's winners rotate to the back of the
//     working order before the next round, and rounds repeat until one
//     produces no wins (so multi-claim teams don't sweep, and the rotation
//     is preserved between rounds). The final order is persisted.
//
//   faab — every pending claim carries a bid; claims resolve league-wide by
//     bid desc (ties: better waiver position, then earlier submission).
//     Winners pay their bid (teams.faab_spent) and can win any number of
//     players in one tick.
//
// Commissioner approval: when leagues.commissioner_approval is on, a winning
// claim does NOT mutate the roster. It resolves the contest (claim ->
// processed, player off waivers, FAAB bid committed) and writes a
// pending_approval transaction; the commissioner's approve applies the
// roster change, and a reject refunds the bid (transactions.bid).
//
// Test/simulation leagues (is_test) and completed seasons are skipped —
// sims advance on simulated time, not the wall clock.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { faabClaimOrder, rotateWinners } from "./logic.ts";

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
    waiver_mode: string | null;
    faab_budget: number | null;
    waiver_period_hours: number;
    roster_config: Record<string, number> | null;
    is_test: boolean;
    season_completed: boolean;
}
interface TeamRow {
    id: string; league_id: string; name: string;
    roster: string[]; starters: string[]; owner_id: string | null;
    ir: string[] | null; faab_spent: number | null;
}
interface ClaimRow {
    id: string; league_id: string; team_id: string;
    add_player_id: string; drop_player_id: string | null;
    team_priority: number; status: string; created_at: string;
    bid: number | null;
}
type ClaimResult = { id: string; status: string; reason?: string };

Deno.serve(async (_req: Request) => {
    try {
        const now = new Date();
        const leagues = await loadDueLeagues(now);
        const out: Record<string, unknown>[] = [];
        for (const lg of leagues) {
            try {
                const summary = await processLeague(lg, now);
                out.push({ league: lg.id, ...summary });
            } catch (err) {
                console.error(`league ${lg.id}:`, err);
                out.push({ league: lg.id, error: String(err) });
            }
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

// Returns real, in-season leagues where the most recent occurrence of
// (process_day, process_hour) is after last_waivers_run_at.
async function loadDueLeagues(now: Date): Promise<LeagueRow[]> {
    const { data, error } = await supa.from("leagues").select(
        "id, waiver_process_day, waiver_process_hour, waiver_priority, " +
        "last_waivers_run_at, commissioner_approval, waiver_mode, faab_budget, " +
        "waiver_period_hours, roster_config, is_test, season_completed"
    );
    if (error) throw error;
    const all = (data ?? []) as LeagueRow[];
    return all.filter(l => {
        // Sim leagues run on simulated time; completed seasons are frozen.
        if (l.is_test || l.season_completed) return false;
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
    const { data: claimRows } = await supa.from("waiver_claims")
        .select("*").eq("league_id", lg.id).eq("status", "pending");
    const claims = (claimRows ?? []) as ClaimRow[];

    const { data: teamRows } = await supa.from("teams").select("*").eq("league_id", lg.id);
    const teams = (teamRows ?? []) as TeamRow[];
    const teamByID = new Map(teams.map(t => [t.id, t]));

    const { data: dropRows } = await supa.from("dropped_players").select("*").eq("league_id", lg.id);
    const onWaivers = new Set<string>(
        ((dropRows ?? []) as { player_id: string }[]).map(r => r.player_id)
    );

    // Working priority order; teams missing from it (edge case) go last.
    const order = [...(lg.waiver_priority ?? [])];
    for (const t of teams) if (!order.includes(t.id)) order.push(t.id);

    const ctx: LeagueContext = {
        lg,
        onWaivers,
        addedThisTick: new Set<string>(),
        // Remaining FAAB per team, tracked in-memory across this tick's wins.
        faabRemaining: new Map(teams.map(t =>
            [t.id, (lg.faab_budget ?? 100) - (t.faab_spent ?? 0)]
        )),
    };

    const processed: ClaimResult[] = [];
    let finalOrder = order;

    if ((lg.waiver_mode ?? "priority") === "faab") {
        // FAAB: one league-wide pass in bid order. No priority rotation —
        // the order is only a tiebreaker.
        const priorityIndex = new Map(order.map((id, i) => [id, i]));
        for (const claim of faabClaimOrder(claims, priorityIndex)) {
            const team = teamByID.get(claim.team_id);
            if (!team) continue;
            processed.push(await attemptClaim(claim, team, ctx));
        }
    } else {
        // Priority: repeated one-win-per-team rounds; each round's winners
        // rotate to the back before the next round.
        const resolved = new Set<string>();
        let working = order;
        for (;;) {
            const roundWinners: string[] = [];
            for (const teamID of working) {
                const team = teamByID.get(teamID);
                if (!team) continue;
                const teamClaims = (claims.filter(c => c.team_id === teamID && !resolved.has(c.id)))
                    .sort((a, b) => a.team_priority - b.team_priority);
                for (const claim of teamClaims) {
                    const result = await attemptClaim(claim, team, ctx);
                    processed.push(result);
                    resolved.add(claim.id);
                    if (result.status === "processed") {
                        roundWinners.push(teamID);
                        break;  // one win per team per round
                    }
                }
            }
            if (roundWinners.length === 0) break;
            working = rotateWinners(working, roundWinners);
        }
        finalOrder = working;
    }

    if (JSON.stringify(finalOrder) !== JSON.stringify(lg.waiver_priority ?? [])) {
        await supa.from("leagues").update({ waiver_priority: finalOrder }).eq("id", lg.id);
    }
    await supa.from("leagues").update({ last_waivers_run_at: now.toISOString() }).eq("id", lg.id);

    return {
        processed: processed.filter(p => p.status === "processed").length,
        failed:    processed.filter(p => p.status === "failed").length,
        skipped:   processed.filter(p => p.status === "skipped").length,
    };
}

interface LeagueContext {
    lg: LeagueRow;
    onWaivers: Set<string>;
    addedThisTick: Set<string>;
    faabRemaining: Map<string, number>;
}

async function attemptClaim(
    claim: ClaimRow, team: TeamRow, ctx: LeagueContext
): Promise<ClaimResult> {
    const { lg, onWaivers, addedThisTick, faabRemaining } = ctx;
    const isFaab = (lg.waiver_mode ?? "priority") === "faab";

    // If someone earlier in this tick already grabbed the player, this claim
    // lost the contest (priority order / bid order handled who wins).
    if (addedThisTick.has(claim.add_player_id)) {
        await failClaim(claim.id, isFaab ? "Outbid — another team won this player."
                                         : "Higher-priority team won this player.");
        return { id: claim.id, status: "failed", reason: "outbid" };
    }

    if (!onWaivers.has(claim.add_player_id)) {
        await failClaim(claim.id, "Player is no longer on waivers.");
        return { id: claim.id, status: "failed", reason: "not_on_waivers" };
    }

    const bid = claim.bid ?? 0;
    if (isFaab) {
        const remaining = faabRemaining.get(team.id) ?? 0;
        if (bid > remaining) {
            await failClaim(claim.id, `Bid ($${bid}) exceeds your remaining FAAB budget ($${Math.max(0, remaining)}).`);
            return { id: claim.id, status: "failed", reason: "over_budget" };
        }
    }

    // Re-pull the team so earlier wins in this same tick are reflected.
    const { data: latest } = await supa.from("teams").select("*").eq("id", team.id).single();
    if (!latest) {
        await failClaim(claim.id, "Team not found.");
        return { id: claim.id, status: "failed", reason: "no_team" };
    }
    const roster = [...latest.roster] as string[];

    if (claim.drop_player_id) {
        if (!roster.includes(claim.drop_player_id)) {
            await failClaim(claim.id, "Drop player is no longer on your roster.");
            return { id: claim.id, status: "failed", reason: "drop_missing" };
        }
        const i = roster.indexOf(claim.drop_player_id);
        roster.splice(i, 1);
    }
    roster.push(claim.add_player_id);

    // Roster-size check against the league's config (IR sits outside the
    // active roster). Mirrors RosterConfig.totalSize incl. flex variants.
    const cfg = lg.roster_config ?? {};
    const totalSize = (cfg.qb ?? 1) + (cfg.rb ?? 2) + (cfg.wr ?? 2) + (cfg.te ?? 1)
        + (cfg.flex ?? 1) + (cfg.superflex ?? 0) + (cfg.wrFlex ?? 0) + (cfg.recFlex ?? 0)
        + (cfg.k ?? 1) + (cfg.def ?? 1) + (cfg.bench ?? 6);
    const irSet = new Set((latest.ir ?? []) as string[]);
    const activeCount = roster.filter((p: string) => !irSet.has(p)).length;
    if (activeCount > totalSize) {
        await failClaim(claim.id, "Adding this player would exceed your roster size — set a drop.");
        return { id: claim.id, status: "failed", reason: "roster_full" };
    }

    // The claim WINS from here on: the contest is resolved, the player comes
    // off waivers, and (FAAB) the bid is committed — regardless of whether
    // the roster change applies now or waits for commissioner approval.
    const held = lg.commissioner_approval === true;

    if (!held) {
        // Blank the dropped player's starter slot in place (slot-positional).
        const starters = ((latest.starters ?? []) as string[])
            .map(s => s === claim.drop_player_id ? "" : s);
        await supa.from("teams").update({ roster, starters }).eq("id", team.id);
        if (claim.drop_player_id) {
            const until = new Date(Date.now() + lg.waiver_period_hours * 3600 * 1000).toISOString();
            await supa.from("dropped_players").upsert({
                league_id: claim.league_id,
                player_id: claim.drop_player_id,
                dropped_at: new Date().toISOString(),
                waiver_until: until,
            });
        }
    }

    if (isFaab && bid >= 0) {
        faabRemaining.set(team.id, (faabRemaining.get(team.id) ?? 0) - bid);
        await supa.from("teams")
            .update({ faab_spent: ((latest.faab_spent ?? 0) as number) + bid })
            .eq("id", team.id);
    }

    await supa.from("dropped_players").delete()
        .eq("league_id", claim.league_id).eq("player_id", claim.add_player_id);
    onWaivers.delete(claim.add_player_id);
    addedThisTick.add(claim.add_player_id);

    await supa.from("waiver_claims").update({
        status: "processed", processed_at: new Date().toISOString(),
    }).eq("id", claim.id);
    await supa.from("transactions").insert({
        league_id: claim.league_id, team_id: team.id,
        kind: "waiver_claim",
        add_player_id: claim.add_player_id,
        drop_player_id: claim.drop_player_id,
        status: held ? "pending_approval" : "completed",
        bid: isFaab ? bid : null,
        note: held ? "Won waiver claim — awaiting commissioner approval." : null,
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
