-- Per-minute cron that invokes the draft_tick edge function. The function
-- itself filters to live drafts whose pick_deadline has passed; off-clock
-- invocations are cheap no-ops.

select cron.unschedule('draft_tick_minute')
    where exists (select 1 from cron.job where jobname = 'draft_tick_minute');

select cron.schedule(
    'draft_tick_minute',
    '* * * * *',
    $$select public.invoke_edge_function('draft_tick')$$
);
