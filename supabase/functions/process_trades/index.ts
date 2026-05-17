// Hourly cron driver for trades:
//   - Closes voting windows past voting_ends_at by calling tally_trade_vote
//     once more; non-vetoed trades fall through to pending_execution.
//   - Retries pending_execution trades via attempt_execute_trade so locked
//     players that have since unlocked cause the swap to land.
//
// Both code paths are safe to call repeatedly — the RPCs short-circuit when
// the trade isn't in the expected state.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

interface TradeRow { id: string; status: string; voting_ends_at: string | null; }

Deno.serve(async (_req: Request) => {
    try {
        const now = new Date();
        const summary: Record<string, number> = {
            votingClosed: 0, executed: 0, stillLocked: 0, errors: 0,
        };

        // 1. Voting windows that have expired.
        const { data: voting } = await supa.from("trades")
            .select("id, status, voting_ends_at")
            .eq("status", "voting");
        const expiredVotes = (voting ?? []).filter((t: TradeRow) =>
            t.voting_ends_at && new Date(t.voting_ends_at).getTime() <= now.getTime()
        );
        for (const t of expiredVotes) {
            try {
                // Tally first. If still 'voting' afterwards (no veto majority),
                // move into pending_execution and try to execute.
                await supa.rpc("tally_trade_vote", { p_trade_id: t.id });
                const { data: refreshed } = await supa.from("trades")
                    .select("status").eq("id", t.id).single();
                if (refreshed?.status === "voting") {
                    await supa.from("trades").update({
                        status: "pending_execution",
                        resolved_at: now.toISOString(),
                    }).eq("id", t.id);
                    await supa.rpc("attempt_execute_trade", { p_trade_id: t.id });
                    const { data: post } = await supa.from("trades")
                        .select("status").eq("id", t.id).single();
                    if (post?.status === "executed") summary.executed += 1;
                    else if (post?.status === "pending_execution") summary.stillLocked += 1;
                }
                summary.votingClosed += 1;
            } catch {
                summary.errors += 1;
            }
        }

        // 2. Retry pending_execution trades — locked players may have unlocked.
        const { data: pending } = await supa.from("trades")
            .select("id").eq("status", "pending_execution");
        for (const t of (pending ?? [])) {
            try {
                await supa.rpc("attempt_execute_trade", { p_trade_id: t.id });
                const { data: post } = await supa.from("trades")
                    .select("status").eq("id", t.id).single();
                if (post?.status === "executed") summary.executed += 1;
                else if (post?.status === "pending_execution") summary.stillLocked += 1;
            } catch {
                summary.errors += 1;
            }
        }

        return new Response(JSON.stringify(summary), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});
