-- Schedule sync_sim_history to backfill the current + prior season nightly,
-- so we keep depth charts, inactives, and injury reports current. Historical
-- seasons (2016..) are backfilled manually with curl, same pattern as
-- sync_nflverse.

select cron.unschedule('sync_sim_history_daily')
    where exists (select 1 from cron.job where jobname = 'sync_sim_history_daily');

select cron.schedule(
    'sync_sim_history_daily',
    '15 10 * * *',   -- 10:15 UTC, after nflverse + MFL syncs
    $$select public.invoke_edge_function('sync_sim_history')$$
);
