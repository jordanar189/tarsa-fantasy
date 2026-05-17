-- Daily cron entries for the two new sync jobs added in Phase 1 of the
-- stats overhaul. Both run early UTC alongside the existing sync_nflverse
-- job so the morning refresh fans out together.

select cron.unschedule('sync_schedules_daily')
    where exists (select 1 from cron.job where jobname = 'sync_schedules_daily');
select cron.schedule(
    'sync_schedules_daily',
    '30 9 * * *',
    $$select public.invoke_edge_function('sync_schedules')$$
);

select cron.unschedule('sync_snap_counts_daily')
    where exists (select 1 from cron.job where jobname = 'sync_snap_counts_daily');
select cron.schedule(
    'sync_snap_counts_daily',
    '45 9 * * *',
    $$select public.invoke_edge_function('sync_snap_counts')$$
);
