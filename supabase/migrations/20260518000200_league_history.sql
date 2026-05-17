-- League history: multi-season tracking with manual "Complete season" +
-- "Roll over" flow. Triggered exclusively by the commissioner via the
-- complete_league_season() and rollover_league() RPCs.
--
-- Tables:
--   leagues: add parent_league_id, season_completed, season_completed_at
--   league_seasons: one snapshot row per completed (league, season)
--   league_matchups: per-week head-to-head history for opponent lookups

alter table public.leagues
    add column if not exists parent_league_id uuid references public.leagues(id) on delete set null,
    add column if not exists season_completed boolean not null default false,
    add column if not exists season_completed_at timestamptz;

create index if not exists leagues_parent_idx on public.leagues (parent_league_id);

create table if not exists public.league_seasons (
    id                          uuid primary key default gen_random_uuid(),
    league_id                   uuid not null references public.leagues(id) on delete cascade,
    season                      int  not null,
    standings                   jsonb not null,        -- serialized [StandingsRow]
    scoring_leader_team_id      uuid,
    scoring_leader_team_name    text,
    archived_at                 timestamptz not null default now(),
    unique (league_id, season)
);
create index if not exists league_seasons_league_idx on public.league_seasons (league_id);

alter table public.league_seasons enable row level security;
drop policy if exists "league_seasons_read" on public.league_seasons;
-- Read: any signed-in user (history shouldn't be secret among members; the
-- league_id itself is hard to guess and pages already require membership
-- context to discover).
create policy "league_seasons_read"
    on public.league_seasons for select using (auth.role() = 'authenticated');

create table if not exists public.league_matchups (
    league_id        uuid not null references public.leagues(id) on delete cascade,
    season           int  not null,
    week             int  not null,
    home_team_id     uuid not null,
    away_team_id     uuid not null,
    home_user_id     uuid,
    away_user_id     uuid,
    home_points      numeric not null default 0,
    away_points      numeric not null default 0,
    primary key (league_id, season, week, home_team_id)
);
create index if not exists league_matchups_users_idx
    on public.league_matchups (home_user_id, away_user_id);
create index if not exists league_matchups_league_season_idx
    on public.league_matchups (league_id, season);

alter table public.league_matchups enable row level security;
drop policy if exists "league_matchups_read" on public.league_matchups;
create policy "league_matchups_read"
    on public.league_matchups for select using (auth.role() = 'authenticated');

-- RPC: complete_league_season. Commissioner-only. Computes final standings
-- from the league's schedule (walking matchups for each week), snapshots
-- the per-week matchup rows, writes the league_seasons archive row, and
-- flips season_completed = true. Idempotent — re-running overwrites the
-- archive for that season.
create or replace function public.complete_league_season(
    p_league_id uuid
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

    -- The client passes pre-computed standings + matchup payloads. This RPC
    -- is intentionally a "freeze whatever the app shows" operation rather
    -- than re-deriving from raw data — game scoring is computed app-side
    -- with the league's scoring config and roster snapshots, and we don't
    -- want to duplicate that logic in plpgsql.
    --
    -- For v1 we accept the simplest contract: caller is responsible for
    -- calling write_league_matchups + write_league_season_archive first;
    -- this RPC just sets the flags. Keeps the door open for richer
    -- server-side aggregation later.

    update public.leagues
       set season_completed = true,
           season_completed_at = now()
     where id = p_league_id
     returning * into lg;
    return lg;
end$$;

-- Writer: client supplies the standings JSONB + scoring leader.
create or replace function public.write_league_season_archive(
    p_league_id              uuid,
    p_season                 int,
    p_standings              jsonb,
    p_scoring_leader_team_id uuid,
    p_scoring_leader_name    text
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
        scoring_leader_team_id, scoring_leader_team_name, archived_at
    ) values (
        p_league_id, p_season, p_standings,
        p_scoring_leader_team_id, p_scoring_leader_name, now()
    )
    on conflict (league_id, season) do update
       set standings = excluded.standings,
           scoring_leader_team_id = excluded.scoring_leader_team_id,
           scoring_leader_team_name = excluded.scoring_leader_team_name,
           archived_at = excluded.archived_at;
end$$;

-- Writer: bulk insert/replace this league-season's matchup history.
-- Payload is a JSON array of objects: {week, home_team_id, away_team_id,
-- home_user_id, away_user_id, home_points, away_points}.
create or replace function public.write_league_matchups(
    p_league_id uuid, p_season int, p_matchups jsonb
) returns int
language plpgsql security definer set search_path = public as $$
declare
    is_commish boolean;
    inserted   int := 0;
    m          jsonb;
begin
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = p_league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can write matchup history';
    end if;

    -- Replace anything we already wrote for this league/season.
    delete from public.league_matchups
     where league_id = p_league_id and season = p_season;

    for m in select * from jsonb_array_elements(p_matchups) loop
        insert into public.league_matchups (
            league_id, season, week,
            home_team_id, away_team_id,
            home_user_id, away_user_id,
            home_points, away_points
        ) values (
            p_league_id, p_season,
            (m->>'week')::int,
            (m->>'home_team_id')::uuid,
            (m->>'away_team_id')::uuid,
            nullif(m->>'home_user_id', '')::uuid,
            nullif(m->>'away_user_id', '')::uuid,
            coalesce((m->>'home_points')::numeric, 0),
            coalesce((m->>'away_points')::numeric, 0)
        );
        inserted := inserted + 1;
    end loop;
    return inserted;
end$$;

-- RPC: rollover_league. Spawns a new league row for next season, owned by
-- the same commish, cloned settings, parent_league_id wired to the parent.
-- Teams are NOT cloned by this RPC — the client calls existing team-create
-- machinery after the league row exists. (Keeping this server-side simple.)
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

    -- Generate a fresh 8-hex join code.
    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));

    insert into public.leagues (
        name, season, scoring, creator_id, roster_config, schedule, join_code,
        waiver_process_day, waiver_process_hour, waiver_period_hours,
        commissioner_approval, waiver_priority,
        trade_approval, trade_deadline, trade_vote_hours,
        parent_league_id
    ) values (
        coalesce(nullif(p_new_name, ''), parent.name),
        p_new_season,
        parent.scoring,
        parent.creator_id,
        parent.roster_config,
        '[]'::jsonb,            -- empty schedule; client populates after teams
        new_code,
        parent.waiver_process_day,
        parent.waiver_process_hour,
        parent.waiver_period_hours,
        parent.commissioner_approval,
        '{}'::text[],           -- fresh priority order; client may reorder
        parent.trade_approval,
        null,                   -- new season starts without a trade deadline
        parent.trade_vote_hours,
        parent.id
    )
    returning * into child;
    return child;
end$$;
