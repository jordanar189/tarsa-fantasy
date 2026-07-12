-- IDP part 2: lineup slots + season-total scoring.
--
-- roster_config gains dl / lb / db / idpFlex starter counts (jsonb — no table
-- change), so the auction/draft sizing helper must count them. And the
-- career/season aggregates gain the standard-weight IDP term so defenders
-- rank like K/DST do: the weights below mirror ScoringSettings' IDP defaults
-- (solo 1, assist 0.5, TFL 2, sack 4, QB hit 1, INT 6, PD 1.5, FF 4, FR 2,
-- TD 6, safety 2) and apply only off the DST branch — def_points_allowed is
-- null on every individual row, and all IDP columns are zero on offensive
-- rows, so nothing else moves.

create or replace function public.roster_config_total_size(rc jsonb)
returns int language sql immutable as $$
    select coalesce((rc->>'qb')::int, 1)
         + coalesce((rc->>'rb')::int, 2)
         + coalesce((rc->>'wr')::int, 2)
         + coalesce((rc->>'te')::int, 1)
         + coalesce((rc->>'flex')::int, 1)
         + coalesce((rc->>'superflex')::int, 0)
         + coalesce((rc->>'wrFlex')::int, 0)
         + coalesce((rc->>'recFlex')::int, 0)
         + coalesce((rc->>'k')::int, 1)
         + coalesce((rc->>'def')::int, 1)
         + coalesce((rc->>'dl')::int, 0)
         + coalesce((rc->>'lb')::int, 0)
         + coalesce((rc->>'db')::int, 0)
         + coalesce((rc->>'idpFlex')::int, 0)
         + coalesce((rc->>'bench')::int, 6)
$$;

-- Same four keys for the roster-write capacity check (add_free_agent /
-- waiver processing read this one).
create or replace function public.league_total_roster_size(cfg jsonb) returns integer
language sql immutable as $$
    select coalesce((cfg->>'qb')::int, 1) + coalesce((cfg->>'rb')::int, 2)
         + coalesce((cfg->>'wr')::int, 2) + coalesce((cfg->>'te')::int, 1)
         + coalesce((cfg->>'flex')::int, 1) + coalesce((cfg->>'superflex')::int, 0)
         + coalesce((cfg->>'wrFlex')::int, 0) + coalesce((cfg->>'recFlex')::int, 0)
         + coalesce((cfg->>'k')::int, 1) + coalesce((cfg->>'def')::int, 1)
         + coalesce((cfg->>'dl')::int, 0) + coalesce((cfg->>'lb')::int, 0)
         + coalesce((cfg->>'db')::int, 0) + coalesce((cfg->>'idpFlex')::int, 0)
         + coalesce((cfg->>'bench')::int, 6)
$$;

-- Rebuild the season-totals materialized view with the IDP term. Same
-- drop + recreate convention as 20260607 (its origin): the definition below
-- is that one plus the `else` (non-DST) branch of the special-points case.
-- player_career reads the view by name and needs no redefinition; the daily
-- concurrent-refresh cron job keys on the view name and survives the rebuild.
drop materialized view if exists public.player_season_totals;
create materialized view public.player_season_totals as
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
                else
                    -- Individual defender line (standard IDP weights).
                    pg.def_tackles_solo
                    + pg.def_tackle_assists * 0.5
                    + pg.def_tackles_for_loss * 2
                    + pg.def_sacks * 4
                    + pg.def_qb_hits
                    + pg.def_interceptions * 6
                    + pg.def_pass_defended * 1.5
                    + pg.def_fumbles_forced * 4
                    + pg.def_fumble_recoveries * 2
                    + pg.def_tds * 6
                    + pg.def_safeties * 2
                end
        ) as special_points
    from public.player_games pg
    join public.players_cache pc on pc.id = pg.player_id
    group by pg.player_id, pg.season, upper(pc.position)
    with data;

create unique index if not exists player_season_totals_pk
    on public.player_season_totals (player_id, season);
create index if not exists player_season_totals_season_pos_idx
    on public.player_season_totals (season, position);
