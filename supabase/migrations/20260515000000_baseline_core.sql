-- Baseline for the hand-created core schema: profiles, leagues, teams, and
-- the auth.users -> profiles trigger. These objects were originally created
-- in the dashboard before migrations existed, which meant the most
-- security-critical RLS in the app lived outside version control and a fresh
-- `supabase db push` could not reconstruct the database.
--
-- Captured from a live `pg_dump --schema-only` (2026-07-07). Dated BEFORE
-- every existing migration so a fresh replay creates these tables first
-- (20260516000400_waivers.sql etc. ALTER them). Everything here is
-- idempotent — on production, where the objects already exist, this file
-- applies as a no-op.
--
-- Tables are created in their FULL current shape (including columns that
-- later migrations add): all later ALTERs use `add column if not exists`,
-- so they no-op on a fresh replay. Constraints live inline in CREATE TABLE,
-- which is skipped wholesale when the table already exists.

-- Profiles first: leagues.creator_id and teams.owner_id reference it.
-- One row per auth user, created by the on_auth_user_created trigger below.
create table if not exists public.profiles (
    id          uuid not null,
    username    text not null,
    created_at  timestamptz default now(),
    is_admin    boolean not null default false,
    theme       text not null default 'dark',
    is_tester   boolean not null default false,
    constraint profiles_pkey primary key (id),
    constraint profiles_username_key unique (username),
    constraint profiles_theme_check check (theme in ('system', 'light', 'dark')),
    constraint profiles_id_fkey foreign key (id)
        references auth.users (id) on delete cascade
);

create table if not exists public.leagues (
    id                     uuid not null default gen_random_uuid(),
    name                   text not null,
    season                 integer not null,
    scoring                text not null,
    roster_config          jsonb not null,
    schedule               jsonb not null,
    join_code              text not null,
    creator_id             uuid not null,
    created_at             timestamptz default now(),
    waiver_process_day     smallint not null default 3,
    waiver_process_hour    smallint not null default 8,
    waiver_period_hours    smallint not null default 24,
    commissioner_approval  boolean not null default false,
    waiver_priority        text[] not null default '{}',
    last_waivers_run_at    timestamptz,
    trade_approval         text not null default 'none',
    trade_deadline         timestamptz,
    trade_vote_hours       integer not null default 24,
    is_test                boolean not null default false,
    simulated_week         integer,
    parent_league_id       uuid,
    season_completed       boolean not null default false,
    season_completed_at    timestamptz,
    regular_season_weeks   integer,
    playoff_teams          integer not null default 6,
    playoff_reseed         boolean not null default true,
    scoring_settings       jsonb,
    division_names         jsonb not null default '[]',
    champion_team_id       uuid,
    champion_team_name     text,
    is_dynasty             boolean not null default false,
    weeks_per_round        integer not null default 1,
    constraint leagues_pkey primary key (id),
    constraint leagues_join_code_key unique (join_code),
    constraint leagues_creator_id_fkey foreign key (creator_id)
        references public.profiles (id),
    constraint leagues_parent_league_id_fkey foreign key (parent_league_id)
        references public.leagues (id) on delete set null
);

create table if not exists public.teams (
    id              uuid not null default gen_random_uuid(),
    league_id       uuid not null,
    name            text not null,
    owner_id        uuid,
    roster          text[] not null default '{}',
    starters        text[] not null default '{}',
    sort_index      integer not null,
    ir              text[] not null default '{}',
    weekly_lineups  jsonb not null default '{}',
    division        integer,
    logo_url        text,
    color_hex       text,
    abbreviation    text,
    taxi            text[] not null default '{}',
    constraint teams_pkey primary key (id),
    constraint teams_league_id_fkey foreign key (league_id)
        references public.leagues (id) on delete cascade,
    constraint teams_owner_id_fkey foreign key (owner_id)
        references public.profiles (id)
);

create index if not exists leagues_join_code_idx on public.leagues (join_code);
create index if not exists leagues_parent_idx    on public.leagues (parent_league_id);
create index if not exists leagues_is_test_idx   on public.leagues (is_test) where is_test = true;
create index if not exists teams_league_id_idx   on public.teams (league_id);
create index if not exists teams_owner_id_idx    on public.teams (owner_id);

alter table public.profiles enable row level security;
alter table public.leagues  enable row level security;
alter table public.teams    enable row level security;

-- RLS. CREATE POLICY has no IF NOT EXISTS, so each is guarded via
-- pg_policies. Definitions match the live database exactly; two more
-- policies on these tables (teams_commish_update, profiles_update_theme_self)
-- ship in their own later migrations and are deliberately absent here.
do $$
begin
    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'profiles'
          and policyname = 'profiles_read_all') then
        create policy profiles_read_all on public.profiles
            for select using (true);
    end if;
    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'profiles'
          and policyname = 'profiles_insert_self') then
        create policy profiles_insert_self on public.profiles
            for insert with check (auth.uid() = id);
    end if;
    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'profiles'
          and policyname = 'profiles_update_self') then
        create policy profiles_update_self on public.profiles
            for update using (auth.uid() = id);
    end if;

    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'leagues'
          and policyname = 'leagues_read_authed') then
        create policy leagues_read_authed on public.leagues
            for select using (auth.role() = 'authenticated');
    end if;
    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'leagues'
          and policyname = 'leagues_insert_creator') then
        create policy leagues_insert_creator on public.leagues
            for insert with check (creator_id = auth.uid());
    end if;
    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'leagues'
          and policyname = 'leagues_update_creator') then
        create policy leagues_update_creator on public.leagues
            for update using (creator_id = auth.uid());
    end if;
    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'leagues'
          and policyname = 'leagues_delete_creator') then
        create policy leagues_delete_creator on public.leagues
            for delete using (creator_id = auth.uid());
    end if;

    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'teams'
          and policyname = 'teams_read_authed') then
        create policy teams_read_authed on public.teams
            for select using (auth.role() = 'authenticated');
    end if;
    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'teams'
          and policyname = 'teams_insert_creator') then
        create policy teams_insert_creator on public.teams
            for insert with check (exists (
                select 1 from public.leagues
                where leagues.id = teams.league_id
                  and leagues.creator_id = auth.uid()
            ));
    end if;
    -- NOTE (captured as-is): the "owner_id is null" arm is what lets a user
    -- claim an open team, but it also lets ANY signed-in user update any
    -- unclaimed team's row. Tightening this (claim-only column updates,
    -- roster writes via security-definer RPCs) is planned follow-up work —
    -- the baseline's job is to mirror production, not change it.
    if not exists (select 1 from pg_policies
        where schemaname = 'public' and tablename = 'teams'
          and policyname = 'teams_update_owner') then
        create policy teams_update_owner on public.teams
            for update using (
                owner_id = auth.uid()
                or (owner_id is null and auth.role() = 'authenticated')
            );
    end if;
end$$;

-- Auto-create a profile row for every new auth user. The trigger lives on
-- auth.users (outside the public-schema dump), so it's recreated here with
-- the conventional Supabase name.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    insert into public.profiles (id, username)
    values (new.id, coalesce(new.raw_user_meta_data->>'username', new.email));
    return new;
end;
$$;

do $$
begin
    if not exists (
        select 1 from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'auth' and c.relname = 'users'
          and t.tgname = 'on_auth_user_created'
    ) then
        create trigger on_auth_user_created
            after insert on auth.users
            for each row execute function public.handle_new_user();
    end if;
exception when insufficient_privilege then
    -- Hosted projects sometimes restrict trigger DDL on auth.users; the
    -- trigger already exists there, so a fresh local/staging replay is the
    -- only path that reaches this. Surface it rather than failing the chain.
    raise warning 'could not create on_auth_user_created on auth.users — create it manually';
end$$;

-- Standard Supabase table grants (RLS does the real gating).
grant all on table public.profiles to anon, authenticated, service_role;
grant all on table public.leagues  to anon, authenticated, service_role;
grant all on table public.teams    to anon, authenticated, service_role;
grant all on function public.handle_new_user() to anon, authenticated, service_role;
