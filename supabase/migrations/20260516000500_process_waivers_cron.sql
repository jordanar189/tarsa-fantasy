-- Hourly cron that invokes the process_waivers edge function. The function
-- itself filters to leagues whose configured process time has passed since
-- last_waivers_run_at; off-hour invocations are cheap no-ops.

select cron.unschedule('process_waivers_hourly')
    where exists (select 1 from cron.job where jobname = 'process_waivers_hourly');

select cron.schedule(
    'process_waivers_hourly',
    '5 * * * *',  -- 5 min past every hour
    $$select public.invoke_edge_function('process_waivers')$$
);
