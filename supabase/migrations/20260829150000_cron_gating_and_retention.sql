-- Applied to prod 2026-08-29 via dashboard SQL (not via `supabase db push`).
-- Idempotent: safe to re-apply.
-- Cron jobs only invoke their edge function when there is work, so nothing
-- fires (and nothing can stack up) while the DB is under pressure.
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'draft_tick_minute'),
  schedule := '* * * * *', active := true, command :=
  $c$select public.invoke_edge_function('draft_tick') where exists (select 1 from public.drafts where status = 'live')$c$);

select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'dispatch_push_minute'),
  schedule := '* * * * *', active := true, command :=
  $c$select public.invoke_edge_function('send_push') where exists (select 1 from public.push_notifications where status in ('scheduled','sending') and (scheduled_at is null or scheduled_at <= now())) or exists (select 1 from public.push_events where sent_at is null)$c$);

-- Gated to game windows (kickoff -15 min .. +4.5 h); the function itself is
-- a no-op outside them, but with the gate it isn't even invoked.
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'sync_espn_live_minute'),
  schedule := '* * * * *', active := true, command :=
  $c$select public.invoke_edge_function('sync_espn_live') where exists (select 1 from public.nfl_schedules where kickoff between now() - interval '4 hours 30 minutes' and now() + interval '15 minutes')$c$);

-- pg_cron never prunes its run history (was 447k rows / 83 MB).
select cron.schedule('cleanup_cron_history', '30 4 * * *',
  $c$delete from cron.job_run_details where end_time < now() - interval '7 days'$c$);
