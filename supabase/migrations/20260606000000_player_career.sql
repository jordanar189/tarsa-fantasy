-- Player career table, aggregated server-side.
--
-- The Career tab on the player detail page used to download every available
-- season's full snapshot (all ~3K players + ~50K games) just to render one
-- player's ~10-row career table — it needed the league-wide field to compute
-- each season's position rank. This RPC does that aggregation in Postgres and
-- returns only the target player's rows, so the client makes one sub-100ms
-- round-trip instead of fetching and crunching every season.
--
-- Mirrors the app's scoring exactly (Models.swift / Fantasy.swift):
--   • Offense points use either the named preset's precomputed nflverse field
--     (p_use_custom = false) or the league's custom per-stat coefficients
--     (p_use_custom = true, computed from the raw stat line).
--   • Special (kicker + DST) points ALWAYS use standard weights and are summed
--     per game — the DST points-allowed tier is per-game / non-additive. This
--     matches SeasonTotals.specialPoints, which custom league scoring also
--     leaves at standard weights.
--   • Position rank is computed within each season's own field under the same
--     points formula, so "WR12 of 90" matches what the client would compute.

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
    -- Quoted: `position` is a keyword that can't be a function/type name, so it
    -- is illegal as an unquoted column name in a RETURNS TABLE clause. Quoting
    -- keeps the output column (and the JSON key the client decodes) as `position`.
    "position"              text,
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
        select distinct season
        from public.player_games
        where player_id = p_player_id
    ),
    -- Per (player, season) aggregates for every player who logged a game in a
    -- season the target player also played — the field we rank within.
    totals as (
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
            -- Standard-weight kicker + DST points, summed per game.
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
        where pg.season in (select season from target_seasons)
        group by pg.player_id, pg.season, upper(pc.position)
    ),
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
        from totals t
    ),
    -- Rank within (season, position). Players with no position are excluded
    -- from ranking (matches Fantasy.positionRanks) but still surface below.
    -- row_number() (not rank/dense_rank) mirrors the client's sorted+enumerated
    -- ranking, which gives tied players distinct consecutive ranks (1, 2 — not
    -- 1, 1). player_id breaks ties deterministically so ranks are stable across
    -- calls (the client's sort is unstable, so either tie order is acceptable).
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
