-- Dynasty leagues: a standard-style league whose rosters are never cleared.
-- The only behavioral difference from a standard league is at season rollover —
-- a dynasty league carries every team (owner, branding, and roster) into the
-- next season instead of starting fresh. The flag is additive with a false
-- default so every existing league stays a standard (redraft) league.
alter table public.leagues
    add column if not exists is_dynasty boolean not null default false;

-- Roll a league into the next season. Standard leagues spawn an empty child
-- (owners re-claim with the new join code — a fresh redraft). Dynasty leagues
-- additionally clone every team forward with its owner, branding, and roster
-- (but not the prior season's frozen weekly lineups) so rosters never clear.
-- Cloning runs here in the security-definer RPC so teams owned by other members
-- are copied regardless of row-level security; the client then generates the
-- new schedule over the carried-over teams (reusing the league-creation path).
create or replace function public.rollover_league(
    p_parent_id uuid, p_new_season int, p_new_name text
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
        trade_approval, trade_deadline, trade_vote_hours,
        parent_league_id,
        regular_season_weeks, playoff_teams, playoff_reseed,
        scoring_settings, division_names, is_dynasty
    ) values (
        coalesce(nullif(p_new_name, ''), parent.name),
        p_new_season,
        parent.scoring,
        parent.creator_id,
        parent.roster_config,
        '[]'::jsonb,
        new_code,
        parent.waiver_process_day,
        parent.waiver_process_hour,
        parent.waiver_period_hours,
        parent.commissioner_approval,
        '{}'::text[],
        parent.trade_approval,
        null,
        parent.trade_vote_hours,
        parent.id,
        parent.regular_season_weeks,
        parent.playoff_teams,
        parent.playoff_reseed,
        parent.scoring_settings,
        parent.division_names,
        parent.is_dynasty
    )
    returning * into child;

    if parent.is_dynasty then
        insert into public.teams (
            id, league_id, name, owner_id, sort_index, division,
            roster, starters, ir, logo_url, color_hex, abbreviation
        )
        select
            gen_random_uuid(), child.id, t.name, t.owner_id, t.sort_index, t.division,
            t.roster, t.starters, t.ir, t.logo_url, t.color_hex, t.abbreviation
        from public.teams t
        where t.league_id = parent.id;
    end if;

    return child;
end$$;
