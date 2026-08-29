-- Applied to prod 2026-08-29. Idempotent.
-- Overlap guard for cron-driven edge functions: a run must claim its job name
-- first; a second invocation while the first is still running gets `false`
-- and exits. A crashed run's claim goes stale after p_stale (default 2 min).
create table if not exists public.job_runs (
  job text primary key,
  started_at timestamptz,
  finished_at timestamptz,
  last_error text
);
alter table public.job_runs enable row level security;   -- no policies: service_role only

create or replace function public.claim_job(p_job text, p_stale interval default interval '2 minutes')
returns boolean language sql security definer set search_path = public as $f$
  with c as (
    insert into public.job_runs as j (job, started_at, finished_at, last_error)
    values (p_job, now(), null, null)
    on conflict (job) do update
      set started_at = now(), finished_at = null, last_error = null
      where j.finished_at is not null or j.started_at < now() - p_stale
    returning true as ok
  )
  select coalesce((select ok from c), false);
$f$;

create or replace function public.release_job(p_job text, p_error text default null)
returns void language sql security definer set search_path = public as $f$
  update public.job_runs set finished_at = now(), last_error = p_error where job = p_job;
$f$;

revoke all on function public.claim_job(text, interval) from public, anon, authenticated;
revoke all on function public.release_job(text, text) from public, anon, authenticated;
