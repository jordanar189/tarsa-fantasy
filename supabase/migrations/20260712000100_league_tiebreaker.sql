-- Configurable standings tiebreaker among equal-win% teams (feeds playoff
-- seeding): 'points_for' (default, today's behavior), 'h2h' (record within
-- the tied group), or 'points_against' (tougher schedule ranks first).
-- Standings are computed client-side from this flag; no server logic.

alter table public.leagues add column if not exists tiebreaker text not null default 'points_for';

-- Carry the new column through rollover. Redefined from
-- 20260710000000_keepers.sql with tiebreaker added to the insert list.
create or replace function public.rollover_league(
    p_parent_id       uuid,
    p_new_season      int,
    p_new_name        text,
    p_schedule        jsonb  default '[]'::jsonb,
    p_waiver_priority text[] default '{}'::text[],
    p_teams           jsonb  default '[]'::jsonb
) returns public.leagues
language plpgsql security definer set search_path = public as $$
declare
    parent     public.leagues;
    is_commish boolean;
    child      public.leagues;
    new_code   text;
begin
    select * into parent from public.leagues where id = p_parent_id;
    if not found then raise exception 'parent league not found'; end if;
    select (parent.creator_id = auth.uid()) into is_commish;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can roll over the league';
    end if;

    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));

    insert into public.leagues (
        name, season, scoring, creator_id, roster_config, schedule, join_code,
        waiver_process_day, waiver_process_hour, waiver_period_hours,
        commissioner_approval, waiver_priority,
        waiver_mode, faab_budget,
        trade_approval, trade_deadline, trade_vote_hours,
        parent_league_id,
        regular_season_weeks, playoff_teams, playoff_reseed, weeks_per_round,
        scoring_settings, division_names, is_dynasty, keeper_count, tiebreaker
    ) values (
        coalesce(nullif(p_new_name, ''), parent.name),
        p_new_season,
        parent.scoring,
        parent.creator_id,
        parent.roster_config,
        coalesce(p_schedule, '[]'::jsonb),
        new_code,
        parent.waiver_process_day,
        parent.waiver_process_hour,
        parent.waiver_period_hours,
        parent.commissioner_approval,
        coalesce(p_waiver_priority, '{}'::text[]),
        parent.waiver_mode,
        parent.faab_budget,
        parent.trade_approval,
        null,
        parent.trade_vote_hours,
        parent.id,
        parent.regular_season_weeks,
        parent.playoff_teams,
        parent.playoff_reseed,
        parent.weeks_per_round,
        parent.scoring_settings,
        parent.division_names,
        parent.is_dynasty,
        coalesce(parent.keeper_count, 0),
        coalesce(parent.tiebreaker, 'points_for')
    )
    returning * into child;

    if jsonb_typeof(p_teams) = 'array' and jsonb_array_length(p_teams) > 0 then
        insert into public.teams (
            id, league_id, name, owner_id, sort_index, division,
            roster, starters, ir, taxi, logo_url, color_hex, abbreviation
        )
        select
            x.id, child.id, x.name, x.owner_id, x.sort_index, x.division,
            coalesce(x.roster, '{}'), coalesce(x.starters, '{}'),
            coalesce(x.ir, '{}'), coalesce(x.taxi, '{}'),
            x.logo_url, x.color_hex, x.abbreviation
        from jsonb_to_recordset(p_teams) as x(
            id uuid, name text, owner_id uuid, sort_index int, division int,
            roster text[], starters text[], ir text[], taxi text[],
            logo_url text, color_hex text, abbreviation text
        );
    end if;

    return child;
end$$;
