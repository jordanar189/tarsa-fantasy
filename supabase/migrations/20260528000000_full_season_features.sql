-- Full-season build-out: configurable regular-season length, playoffs +
-- champion, custom per-stat scoring, divisions, IR roster slots, and team
-- customization (logo + accent color).
--
-- All columns are additive with safe defaults so existing leagues/teams keep
-- working: a NULL regular_season_weeks falls back to the stored schedule
-- length app-side, NULL scoring_settings means "use the named preset", an
-- empty division_names means "no divisions", etc.

-- Leagues: season structure + scoring + divisions + frozen champion.
alter table public.leagues
    add column if not exists regular_season_weeks int,
    add column if not exists playoff_teams        int     not null default 6,
    add column if not exists playoff_reseed        boolean not null default true,
    add column if not exists scoring_settings      jsonb,
    add column if not exists division_names        jsonb   not null default '[]'::jsonb,
    add column if not exists champion_team_id      uuid,
    add column if not exists champion_team_name    text;

-- Teams: IR stash + per-week frozen lineups + division membership + branding.
-- weekly_lineups is a jsonb object keyed by fantasy week ("3": ["pid", ...]).
alter table public.teams
    add column if not exists ir             text[] not null default '{}',
    add column if not exists weekly_lineups jsonb  not null default '{}'::jsonb,
    add column if not exists division       int,
    add column if not exists logo_url       text,
    add column if not exists color_hex      text;

-- League season archive: record the playoff champion alongside the standings.
alter table public.league_seasons
    add column if not exists champion_team_id   uuid,
    add column if not exists champion_team_name text;

-- Replace the archive writer to also persist the champion. Drop the old
-- 5-arg version first so we don't create an ambiguous overload.
drop function if exists public.write_league_season_archive(uuid, int, jsonb, uuid, text);

create or replace function public.write_league_season_archive(
    p_league_id              uuid,
    p_season                 int,
    p_standings              jsonb,
    p_scoring_leader_team_id uuid,
    p_scoring_leader_name    text,
    p_champion_team_id       uuid default null,
    p_champion_team_name     text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
    is_commish boolean;
begin
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = p_league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can write the archive';
    end if;

    insert into public.league_seasons (
        league_id, season, standings,
        scoring_leader_team_id, scoring_leader_team_name,
        champion_team_id, champion_team_name, archived_at
    ) values (
        p_league_id, p_season, p_standings,
        p_scoring_leader_team_id, p_scoring_leader_name,
        p_champion_team_id, p_champion_team_name, now()
    )
    on conflict (league_id, season) do update
       set standings = excluded.standings,
           scoring_leader_team_id = excluded.scoring_leader_team_id,
           scoring_leader_team_name = excluded.scoring_leader_team_name,
           champion_team_id = excluded.champion_team_id,
           champion_team_name = excluded.champion_team_name,
           archived_at = excluded.archived_at;
end$$;

-- Replace complete_league_season to also stamp the champion on the league.
drop function if exists public.complete_league_season(uuid);

create or replace function public.complete_league_season(
    p_league_id          uuid,
    p_champion_team_id   uuid default null,
    p_champion_team_name text default null
) returns public.leagues
language plpgsql security definer set search_path = public as $$
declare
    lg          public.leagues;
    is_commish  boolean;
begin
    select * into lg from public.leagues where id = p_league_id for update;
    if not found then raise exception 'league not found'; end if;
    select (lg.creator_id = auth.uid()) into is_commish;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can complete the season';
    end if;

    update public.leagues
       set season_completed = true,
           season_completed_at = now(),
           champion_team_id = p_champion_team_id,
           champion_team_name = p_champion_team_name
     where id = p_league_id
     returning * into lg;
    return lg;
end$$;

-- Carry the new season-structure settings over when rolling a league into the
-- next season. Champion resets (new season hasn't been played).
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
        scoring_settings, division_names
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
        parent.division_names
    )
    returning * into child;
    return child;
end$$;
