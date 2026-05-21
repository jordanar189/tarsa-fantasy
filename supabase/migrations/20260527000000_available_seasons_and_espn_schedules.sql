-- Surfaces an upcoming NFL season (e.g. 2026) in the app as soon as its
-- schedule is known, before any games are played.
--
-- Two pieces:
--   1. `available_seasons` view — the union of seasons that have player stats
--      (the `seasons` table, written by sync_nflverse) and seasons that only
--      have a schedule so far (distinct seasons in `nfl_schedules`). The app's
--      season picker reads this instead of `seasons` directly, so a freshly
--      released schedule makes the season selectable for league/draft setup.
--   2. Cron for `sync_schedules_espn` — pulls the upcoming season's matchups
--      from ESPN (published the moment the NFL releases the schedule, ahead of
--      the community nflverse CSV). Writes nflverse-style game_ids so its rows
--      merge with sync_schedules rather than duplicating.

-- 1. Union view. security_invoker so the underlying RLS (authenticated read on
--    both source tables) still applies through the view.
--
--    nfl_schedules mirrors nflverse's full games.csv (back to 1999), so the
--    schedule side is constrained to seasons BEYOND the latest stats season —
--    i.e. genuinely upcoming years whose schedule is out but whose games haven't
--    been played. That surfaces 2026 without flooding the picker with ancient
--    schedule-only years. Once 2026 stats land, max(season) advances and the
--    next scheduled year (2027) takes its place automatically.
create or replace view public.available_seasons
    with (security_invoker = on) as
    select season from public.seasons
    union
    select distinct season from public.nfl_schedules
        where season > (select coalesce(max(season), 0) from public.seasons);

grant select on public.available_seasons to authenticated;

-- Nudge PostgREST to pick up the new view immediately.
notify pgrst, 'reload schema';

-- 2. Daily ESPN schedule sync. Runs at 09:20 UTC, between sync_nflverse (09:00)
--    and the nflverse-based sync_schedules (09:30); idempotent upserts on a
--    shared game_id mean run order doesn't matter. No-ops year-round until ESPN
--    has published the target season(s), so it's safe to run every day.
select cron.unschedule('sync_schedules_espn_daily')
    where exists (select 1 from cron.job where jobname = 'sync_schedules_espn_daily');
select cron.schedule(
    'sync_schedules_espn_daily',
    '20 9 * * *',
    $$select public.invoke_edge_function('sync_schedules_espn')$$
);
