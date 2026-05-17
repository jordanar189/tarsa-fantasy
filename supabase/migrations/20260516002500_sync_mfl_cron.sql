-- MFL feeds (injuries, trending, ADP) refreshed daily. Single function call
-- covers all three feeds. Replaces sync_adp_daily — MFL gives us deeper ADP
-- coverage than FFC, so the FFC cron is no longer needed (historical FFC
-- rows in public.adp will be overwritten naturally as MFL backfills run).
select cron.unschedule('sync_adp_daily')
    where exists (select 1 from cron.job where jobname = 'sync_adp_daily');

select cron.unschedule('sync_mfl_daily')
    where exists (select 1 from cron.job where jobname = 'sync_mfl_daily');
select cron.schedule(
    'sync_mfl_daily',
    '55 9 * * *',
    $$select public.invoke_edge_function('sync_mfl')$$
);
