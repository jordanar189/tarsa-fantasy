-- Preseason game + player stat tracking (live during games, final after).
--
-- Kept in its own tables on purpose: ESPN numbers preseason weeks 1-4 (1 =
-- Hall of Fame weekend) so rows would collide with regular-season weeks in
-- nfl_schedules / live_scores / player_games, preseason must never leak into
-- fantasy scoring or season totals, and roughly a quarter of a preseason box
-- score is players nflverse (and players_cache) has never seen — so stat rows
-- are keyed by ESPN athlete id with the nflverse id attached when known.
--
-- Live delivery is a Realtime BROADCAST (one message per sync run on topic
-- `preseason:<season>`), not postgres_changes: the DB cost is one call per
-- run regardless of how many clients are subscribed. Clients re-fetch what
-- they are showing when the message arrives.

create table if not exists public.preseason_games (
    game_id         text primary key,                 -- ESPN event id
    season          int  not null,
    pre_week        int  not null,                    -- ESPN preseason week 1..4
    week_label      text not null,                    -- "Hall of Fame Weekend", "Preseason Week 1", ...
    home_team       text not null,                    -- nflverse abbreviations (WAS, LAR, ...)
    away_team       text not null,
    home_score      int,
    away_score      int,
    home_linescores int[] not null default '{}',
    away_linescores int[] not null default '{}',
    status          text not null default 'scheduled', -- scheduled | in_progress | final | postponed
    period          int,
    clock           text,
    status_detail   text,                             -- ESPN shortDetail, e.g. "3rd 4:12" / "Final"
    kickoff         timestamptz,
    venue           text,
    scoring_plays   jsonb not null default '[]'::jsonb,
    updated_at      timestamptz not null default now()
);
create index if not exists preseason_games_season_week_idx on public.preseason_games (season, pre_week, kickoff);
create index if not exists preseason_games_kickoff_idx     on public.preseason_games (kickoff);

create table if not exists public.preseason_player_stats (
    game_id           text not null references public.preseason_games (game_id) on delete cascade,
    espn_athlete_id   text not null,
    season            int  not null,
    pre_week          int  not null,
    player_id         text,                           -- players_cache.id (gsis) when the athlete maps
    name              text not null,
    jersey            text,
    team              text not null,
    opponent          text not null,
    is_final          boolean not null default false,
    completions numeric, attempts numeric, passing_yards numeric, passing_tds numeric,
    passing_interceptions numeric, sacks_taken numeric,
    carries numeric, rushing_yards numeric, rushing_tds numeric, rushing_long numeric,
    receptions numeric, targets numeric, receiving_yards numeric, receiving_tds numeric, receiving_long numeric,
    fumbles numeric, fumbles_lost numeric,
    def_tackles_solo numeric, def_tackle_assists numeric, def_sacks numeric, def_tackles_for_loss numeric,
    def_qb_hits numeric, def_pass_defended numeric, def_interceptions numeric, def_tds numeric,
    kick_returns numeric, kick_return_yards numeric, kick_return_tds numeric,
    punt_returns numeric, punt_return_yards numeric, punt_return_tds numeric,
    fg_made numeric, fg_att numeric, fg_long numeric, pat_made numeric, pat_att numeric,
    fantasy_points numeric, fantasy_points_ppr numeric, fantasy_points_half_ppr numeric,
    updated_at        timestamptz not null default now(),
    primary key (game_id, espn_athlete_id)
);
create index if not exists preseason_player_stats_player_idx
    on public.preseason_player_stats (player_id, season) where player_id is not null;
create index if not exists preseason_player_stats_season_week_idx
    on public.preseason_player_stats (season, pre_week);

alter table public.preseason_games        enable row level security;
alter table public.preseason_player_stats enable row level security;
drop policy if exists preseason_games_read on public.preseason_games;
create policy preseason_games_read on public.preseason_games
    for select using ((select auth.role()) = 'authenticated');
drop policy if exists preseason_player_stats_read on public.preseason_player_stats;
create policy preseason_player_stats_read on public.preseason_player_stats
    for select using ((select auth.role()) = 'authenticated');

-- One broadcast per sync run; clients subscribed to `preseason:<season>`
-- re-fetch the games / box score they are showing.
create or replace function public.preseason_broadcast(p_season int, p_pre_week int, p_game_ids text[])
returns void language sql security definer set search_path = public as $f$
    select realtime.send(
        jsonb_build_object('season', p_season, 'pre_week', p_pre_week,
                           'game_ids', to_jsonb(p_game_ids), 'at', now()),
        'preseason_updated',
        'preseason:' || p_season,
        false
    );
$f$;
revoke all on function public.preseason_broadcast(int, int, text[]) from public, anon, authenticated;

-- Per-minute live sync, invoked only inside a preseason game window; daily
-- schedule refresh keeps preseason_games (and therefore the window) current.
select cron.unschedule('sync_espn_preseason_minute')
    where exists (select 1 from cron.job where jobname = 'sync_espn_preseason_minute');
select cron.schedule(
    'sync_espn_preseason_minute',
    '* * * * *',
    $c$select public.invoke_edge_function('sync_espn_preseason')
        where exists (select 1 from public.preseason_games
                       where kickoff between now() - interval '4 hours 30 minutes'
                                         and now() + interval '15 minutes')$c$
);
select cron.unschedule('sync_espn_preseason_daily')
    where exists (select 1 from cron.job where jobname = 'sync_espn_preseason_daily');
select cron.schedule(
    'sync_espn_preseason_daily',
    '10 9 * * *',
    $c$select public.invoke_edge_function('sync_espn_preseason', '{"mode":"schedule"}'::jsonb)$c$
);
