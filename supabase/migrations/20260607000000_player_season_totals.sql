-- Precompute per-(player, season) totals so the Career tab loads instantly.
--
-- player_career previously aggregated player_games + players_cache live on
-- every call: to rank a player within his position each season it had to sum
-- every player's game rows across all the seasons he appeared in — hundreds of
-- thousands of rows per request (~5s). Nothing changes between nflverse syncs,
-- so we do that aggregation once into a materialized view and let the RPC read
-- from it. The per-request work drops to a small indexed scan (one row per
-- player-season) plus an in-memory window for the rank.
--
-- The special (kicker + DST) points expression is the standard-weight per-game
-- sum (DST points-allowed tier is per-game / non-additive), identical to the
-- previous RPC and to SeasonTotals.specialPoints.

create materialized view if not exists public.player_season_totals as
    select
        pg.player_id,
        pg.season,
        upper(pc.position) as position,
        count(*)::int as games_played,
        sum(pg.completions)            as completions,
        sum(pg.attempts)               as attempts,
        sum(pg.passing_yards)          as passing_yards,
        sum(pg.passing_tds)            as passing_tds,
        sum(pg.passing_interceptions)  as passing_interceptions,
        sum(pg.carries)                as carries,
        sum(pg.rushing_yards)          as rushing_yards,
        sum(pg.rushing_tds)            as rushing_tds,
        sum(pg.receptions)             as receptions,
        sum(pg.targets)                as targets,
        sum(pg.receiving_yards)        as receiving_yards,
        sum(pg.receiving_tds)          as receiving_tds,
        sum(pg.fumbles_lost)           as fumbles_lost,
        sum(pg.fantasy_points)         as fantasy_points,
        sum(pg.fantasy_points_ppr)     as fantasy_points_ppr,
        sum(pg.fantasy_points_half_ppr) as fantasy_points_half_ppr,
        sum(
            (pg.fg_made_0_19 + pg.fg_made_20_29 + pg.fg_made_30_39) * 3
            + pg.fg_made_40_49 * 4
            + (pg.fg_made_50_59 + pg.fg_made_60) * 5
            + pg.pat_made
            - pg.fg_missed
            - pg.pat_missed
            + case when pg.def_points_allowed is not null then
                    pg.def_sacks
                    + pg.def_interceptions * 2
                    + pg.def_fumble_recoveries * 2
                    + pg.def_tds * 6
                    + pg.def_safeties * 2
                    + case
                        when pg.def_points_allowed < 1  then 10
                        when pg.def_points_allowed < 7  then 7
                        when pg.def_points_allowed < 14 then 4
                        when pg.def_points_allowed < 21 then 1
                        when pg.def_points_allowed < 28 then 0
                        when pg.def_points_allowed < 35 then -1
                        else -4
                      end
                else 0 end
        ) as special_points
    from public.player_games pg
    join public.players_cache pc on pc.id = pg.player_id
    group by pg.player_id, pg.season, upper(pc.position);

-- (player_id, season) is unique (one position per player in players_cache),
-- which also lets us REFRESH ... CONCURRENTLY without blocking readers.
create unique index if not exists player_season_totals_pk
    on public.player_season_totals (player_id, season);
-- Serves the RPC's "all players in these seasons" scan + the rank partition.
create index if not exists player_season_totals_season_pos_idx
    on public.player_season_totals (season, position);

-- Career table for one player, now reading the precomputed totals. Signature
-- and result shape are unchanged from 20260606000000_player_career.sql; only
-- the source of the per-season aggregates moves to the materialized view.
create or replace function public.player_career(
    p_player_id text,
    p_scoring text default 'ppr',
    p_use_custom boolean default false,
    p_pass_yards_per_point numeric default 25,
    p_pass_td numeric default 4,
    p_interception numeric default -2,
    p_rush_yards_per_point numeric default 10,
    p_rush_td numeric default 6,
    p_rec_yards_per_point numeric default 10,
    p_rec_td numeric default 6,
    p_reception numeric default 0,
    p_fumble_lost numeric default -2
)
returns table (
    season                  int,
    position                text,
    teams                   text[],
    games_played            int,
    completions             numeric,
    attempts                numeric,
    passing_yards           numeric,
    passing_tds             numeric,
    passing_interceptions   numeric,
    carries                 numeric,
    rushing_yards           numeric,
    rushing_tds             numeric,
    receptions              numeric,
    targets                 numeric,
    receiving_yards         numeric,
    receiving_tds           numeric,
    fumbles_lost            numeric,
    fantasy_points          numeric,
    fantasy_points_ppr      numeric,
    fantasy_points_half_ppr numeric,
    special_points          numeric,
    points                  numeric,
    points_per_game         numeric,
    rank                    int,
    total_at_position       int
)
language sql stable security definer set search_path = public as $$
    with target_seasons as (
        select season from public.player_season_totals where player_id = p_player_id
    ),
    -- Every player's pre-aggregated totals for the seasons the target played —
    -- the field we rank within. One row per player-season (cheap), not per game.
    scored as (
        select
            t.*,
            (
                case when p_use_custom then
                    (case when p_pass_yards_per_point > 0 then t.passing_yards / p_pass_yards_per_point else 0 end)
                    + t.passing_tds * p_pass_td
                    + t.passing_interceptions * p_interception
                    + (case when p_rush_yards_per_point > 0 then t.rushing_yards / p_rush_yards_per_point else 0 end)
                    + t.rushing_tds * p_rush_td
                    + (case when p_rec_yards_per_point > 0 then t.receiving_yards / p_rec_yards_per_point else 0 end)
                    + t.receiving_tds * p_rec_td
                    + t.receptions * p_reception
                    + t.fumbles_lost * p_fumble_lost
                else
                    case p_scoring
                        when 'ppr'  then t.fantasy_points_ppr
                        when 'half' then t.fantasy_points_half_ppr
                        else             t.fantasy_points
                    end
                end
                + t.special_points
            ) as points
        from public.player_season_totals t
        where t.season in (select season from target_seasons)
    ),
    -- Rank within (season, position). row_number() (not rank/dense_rank)
    -- mirrors the client's sorted+enumerated ranking: tied players get distinct
    -- consecutive ranks (1, 2 — not 1, 1). player_id breaks ties deterministically.
    ranked as (
        select
            s.player_id,
            s.season,
            (row_number() over (partition by s.season, s.position order by s.points desc, s.player_id))::int as rank,
            (count(*) over (partition by s.season, s.position))::int as total_at_position
        from scored s
        where coalesce(s.position, '') <> ''
    ),
    target_teams as (
        select season, array_agg(team order by first_week) as teams
        from (
            select season, team, min(week) as first_week
            from public.player_games
            where player_id = p_player_id and team <> ''
            group by season, team
        ) q
        group by season
    )
    select
        s.season,
        coalesce(s.position, '') as position,
        coalesce(tt.teams, array[]::text[]) as teams,
        s.games_played,
        s.completions, s.attempts,
        s.passing_yards, s.passing_tds, s.passing_interceptions,
        s.carries, s.rushing_yards, s.rushing_tds,
        s.receptions, s.targets, s.receiving_yards, s.receiving_tds,
        s.fumbles_lost,
        s.fantasy_points, s.fantasy_points_ppr, s.fantasy_points_half_ppr,
        s.special_points,
        round(s.points::numeric, 2) as points,
        round((s.points / greatest(s.games_played, 1))::numeric, 2) as points_per_game,
        r.rank,
        r.total_at_position
    from scored s
    left join ranked r on r.player_id = s.player_id and r.season = s.season
    left join target_teams tt on tt.season = s.season
    where s.player_id = p_player_id
    order by s.season desc;
$$;

grant execute on function public.player_career(
    text, text, boolean, numeric, numeric, numeric, numeric, numeric,
    numeric, numeric, numeric, numeric
) to authenticated;

-- Keep the precompute fresh. player_games only changes meaningfully on the
-- daily nflverse sync (09:00 UTC); refresh after it has settled. CONCURRENTLY
-- (enabled by the unique index) keeps the Career tab readable during refresh.
-- Like the Career tab's live-score handling, current-season totals lag until
-- the next refresh — acceptable for a historical multi-season rollup.
select cron.unschedule('refresh_player_season_totals_daily')
    where exists (select 1 from cron.job where jobname = 'refresh_player_season_totals_daily');
select cron.schedule(
    'refresh_player_season_totals_daily',
    '30 10 * * *',
    $$refresh materialized view concurrently public.player_season_totals$$
);
