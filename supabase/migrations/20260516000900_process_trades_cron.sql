-- Hourly cron that runs process_trades. Closes expired voting windows and
-- retries pending_execution trades whose locked players have unlocked.

select cron.unschedule('process_trades_hourly')
    where exists (select 1 from cron.job where jobname = 'process_trades_hourly');

select cron.schedule(
    'process_trades_hourly',
    '15 * * * *',  -- offset from the other hourly jobs so they don't all fire at :00
    $$select public.invoke_edge_function('process_trades')$$
);
