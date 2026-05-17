-- Defense vs Position (DvP): per (season, week, defending team, position),
-- the total PPR points the team conceded to that position. Two surfaces:
--
--   • dvp_weekly view — raw per-week aggregate. Cheap to query.
--   • dvp_ranks RPC   — returns each team's season-to-date totals + their
--                       1..N rank for the given position. Rank 1 = the
--                       defense that allows the MOST points to that
--                       position (worst defense / best matchup for the
--                       opposing offense). UI buckets ranks 1-8 green,
--                       9-22 yellow, 23-32 red.

create or replace view public.dvp_weekly as
    select
        pg.season,
        pg.week,
        pg.opponent          as team,
        pc.position          as position,
        sum(pg.fantasy_points_ppr) as ppr_allowed,
        sum(pg.fantasy_points)     as std_allowed,
        sum(pg.fantasy_points_half_ppr) as half_allowed,
        count(*)             as players_faced
    from public.player_games pg
    join public.players_cache pc on pc.id = pg.player_id
    where coalesce(pc.position, '') <> ''
      and pg.opponent is not null
      and pg.opponent <> ''
    group by pg.season, pg.week, pg.opponent, pc.position;

create or replace function public.dvp_ranks(
    p_season int, p_position text, p_scoring text default 'ppr'
)
returns table (team text, points_allowed numeric, rank int)
language sql security definer set search_path = public as $$
    with totals as (
        select
            team,
            case p_scoring
                when 'ppr'  then sum(ppr_allowed)
                when 'half' then sum(half_allowed)
                else             sum(std_allowed)
            end as points_allowed
        from public.dvp_weekly
        where season = p_season
          and upper(position) = upper(p_position)
        group by team
    )
    select
        team,
        round(points_allowed::numeric, 2) as points_allowed,
        (rank() over (order by points_allowed desc))::int as rank
    from totals
    order by rank;
$$;
