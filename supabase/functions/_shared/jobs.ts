// Shared plumbing for the cron-driven functions: a per-job lock so overlapping
// invocations can't stack when the DB is slow (the failure mode behind the
// 2026-08-28 outage), and a fetch with a deadline — supabase-js has none, so a
// stalled DB otherwise pins a function for its full 150 s wall clock.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// Runs `fn` only if this job isn't already running. Backed by
// public.claim_job / public.release_job (job_runs table); a run that dies
// without releasing goes stale after claim_job's p_stale (2 min). Returns
// null when the run was skipped.
export async function withJobLock<T>(
    supa: SupabaseClient, job: string, fn: () => Promise<T>,
): Promise<T | null> {
    const { data: claimed, error } = await supa.rpc("claim_job", { p_job: job });
    if (error) throw new Error(`claim_job(${job}): ${error.message}`);
    if (!claimed) return null;
    let failure: string | null = null;
    try {
        return await fn();
    } catch (err) {
        failure = String(err);
        throw err;
    } finally {
        const { error: relErr } = await supa.rpc("release_job", { p_job: job, p_error: failure });
        if (relErr) console.error(`release_job(${job}): ${relErr.message}`);
    }
}

// Drop-in for supabase-js's `global.fetch`: every PostgREST/RPC call aborts
// after `ms` instead of hanging.
export function fetchWithTimeout(ms = 15_000): typeof fetch {
    return (input, init) =>
        fetch(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(ms) });
}
