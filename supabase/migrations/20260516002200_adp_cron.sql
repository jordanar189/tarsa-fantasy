-- Refresh ADP daily during the offseason / pre-draft window. Cheap when FFC
-- has no fresh data (FFC re-publishes around draft season).
select cron.unschedule('sync_adp_daily')
    where exists (select 1 from cron.job where jobname = 'sync_adp_daily');
select cron.schedule(
    'sync_adp_daily',
    '50 9 * * *',
    $$select public.invoke_edge_function('sync_adp')$$
);
