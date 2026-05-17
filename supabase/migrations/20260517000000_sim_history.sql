-- Historical data tables for the Simulation feature. Sims need to recreate
-- the *information environment* of a past season — what fantasy managers
-- saw week-to-week, not just final stats.
--
-- This migration adds:
--   • injury_history     — per-(season, week, player) status snapshots
--   • trending_history   — per-(season, week, player) adds/drops % snapshots
--   • most_started_history — per-(season, week, player) % started snapshots
--   • nfl_team_ranks_history — per-(season, week, team) off/def ranks
--   • depth_charts        — per-(season, week, team, player) depth order
--   • inactives           — per-(season, week, player) game-day inactive list
--   • adp.snapshot_date  — point-in-time ADP support (was season-aggregate)
--   • nfl_schedules cols  — total, weather, roof
--
-- All historical tables follow the same shape: (season, week, ...) primary
-- key, RLS read for authenticated users only.

-- 1. Injury history -----------------------------------------------------------
create table if not exists public.injury_history (
    season           int  not null,
    week             int  not null,    -- 0 = preseason/training-camp report
    player_id        text not null,
    status           text not null,    -- 'Out','Questionable','Doubtful','IR','PUP','Suspended'
    details          text,             -- 'Knee - ACL'
    practice_status  text,             -- 'DNP','LP','FP' from nflverse weekly injury reports
    expected_return  date,
    primary key (season, week, player_id)
);
create index if not exists injury_history_season_week_idx
    on public.injury_history (season, week);
create index if not exists injury_history_player_idx
    on public.injury_history (player_id, season);

alter table public.injury_history enable row level security;
drop policy if exists "injury_history_read" on public.injury_history;
create policy "injury_history_read" on public.injury_history
    for select using (auth.role() = 'authenticated');

-- 2. Trending history (adds/drops % per week) ---------------------------------
create table if not exists public.trending_history (
    season      int  not null,
    week        int  not null,
    player_id   text not null,
    adds_pct    numeric not null default 0,
    drops_pct   numeric not null default 0,
    primary key (season, week, player_id)
);
create index if not exists trending_history_season_week_idx
    on public.trending_history (season, week);
create index if not exists trending_history_adds_idx
    on public.trending_history (season, week, adds_pct desc);

alter table public.trending_history enable row level security;
drop policy if exists "trending_history_read" on public.trending_history;
create policy "trending_history_read" on public.trending_history
    for select using (auth.role() = 'authenticated');

-- 3. Most-started % history ---------------------------------------------------
create table if not exists public.most_started_history (
    season      int  not null,
    week        int  not null,
    player_id   text not null,
    started_pct numeric not null default 0,
    primary key (season, week, player_id)
);
create index if not exists most_started_history_season_week_idx
    on public.most_started_history (season, week);

alter table public.most_started_history enable row level security;
drop policy if exists "most_started_history_read" on public.most_started_history;
create policy "most_started_history_read" on public.most_started_history
    for select using (auth.role() = 'authenticated');

-- 4. Team-rank history --------------------------------------------------------
create table if not exists public.nfl_team_ranks_history (
    season       int  not null,
    week         int  not null,    -- through-end-of-week ranks
    team         text not null,
    pass_offense int,
    rush_offense int,
    pass_defense int,
    rush_defense int,
    primary key (season, week, team)
);
create index if not exists nfl_team_ranks_history_season_week_idx
    on public.nfl_team_ranks_history (season, week);

alter table public.nfl_team_ranks_history enable row level security;
drop policy if exists "nfl_team_ranks_history_read" on public.nfl_team_ranks_history;
create policy "nfl_team_ranks_history_read" on public.nfl_team_ranks_history
    for select using (auth.role() = 'authenticated');

-- 5. Depth charts -------------------------------------------------------------
-- Sourced from nflverse depth_charts CSVs. depth = 1 is starter, 2 is backup, etc.
create table if not exists public.depth_charts (
    season         int  not null,
    week           int  not null,
    team           text not null,
    player_id      text not null,
    position       text not null,   -- 'QB','RB','WR','TE','K' (already filtered)
    depth          int  not null default 1,
    primary key (season, week, team, position, player_id)
);
create index if not exists depth_charts_player_idx
    on public.depth_charts (player_id, season, week);
create index if not exists depth_charts_team_idx
    on public.depth_charts (season, week, team);

alter table public.depth_charts enable row level security;
drop policy if exists "depth_charts_read" on public.depth_charts;
create policy "depth_charts_read" on public.depth_charts
    for select using (auth.role() = 'authenticated');

-- 6. Inactives ---------------------------------------------------------------
-- Game-day inactives. Sourced from nflverse weekly_rosters where status
-- indicates the player was on IR / suspended / inactive that week.
create table if not exists public.inactives (
    season      int  not null,
    week        int  not null,
    player_id   text not null,
    status      text not null,        -- 'INA','IR','PUP','SUSP','DNR'
    reason      text,
    primary key (season, week, player_id)
);
create index if not exists inactives_season_week_idx
    on public.inactives (season, week);
create index if not exists inactives_player_idx
    on public.inactives (player_id, season);

alter table public.inactives enable row level security;
drop policy if exists "inactives_read" on public.inactives;
create policy "inactives_read" on public.inactives
    for select using (auth.role() = 'authenticated');

-- 7. ADP: add snapshot_date for point-in-time draft realism ------------------
-- Existing `adp` table is (season, scoring, player_id) — only one snapshot per
-- season. Add snapshot_date so we can store weekly draft-window snapshots.
-- The pre-existing rows become snapshot_date = (season-08-25) — a reasonable
-- "draft week" anchor for the season-aggregate value we already have.
alter table public.adp
    add column if not exists snapshot_date date;

-- One-time backfill: existing rows get a default snapshot_date of Aug 25 of
-- their season — close to typical fantasy draft windows. Idempotent.
update public.adp
   set snapshot_date = make_date(season, 8, 25)
 where snapshot_date is null;

-- Switch primary key to include snapshot_date. Drop the old PK first.
do $$
begin
    if exists (
        select 1 from pg_constraint
         where conname = 'adp_pkey' and conrelid = 'public.adp'::regclass
    ) then
        alter table public.adp drop constraint adp_pkey;
    end if;
end $$;

alter table public.adp
    alter column snapshot_date set not null;

alter table public.adp
    add constraint adp_pkey primary key (season, scoring, snapshot_date, player_id);

create index if not exists adp_season_scoring_date_idx
    on public.adp (season, scoring, snapshot_date desc);

-- 8. nfl_schedules: total + weather + roof ----------------------------------
alter table public.nfl_schedules
    add column if not exists total          numeric,           -- Vegas O/U
    add column if not exists temp_f         int,               -- game-time temp
    add column if not exists wind_mph       int,               -- game-time wind
    add column if not exists precipitation  text,              -- 'rain','snow','clear'
    add column if not exists roof           text,              -- 'outdoors','dome','closed','open'
    add column if not exists surface        text;              -- 'grass','fieldturf','astroturf'

-- 9. dvp_ranks: add up_to_week parameter for clamped per-week views ----------
-- Recreate dvp_ranks with an optional p_up_to_week. Existing 3-arg callers
-- keep working (full-season aggregate); new callers can pass a week ceiling.
drop function if exists public.dvp_ranks(int, text, text);

create or replace function public.dvp_ranks(
    p_season       int,
    p_position     text,
    p_scoring      text default 'ppr',
    p_up_to_week   int  default null
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
          and (p_up_to_week is null or week <= p_up_to_week)
        group by team
    )
    select
        team,
        round(points_allowed::numeric, 2) as points_allowed,
        (rank() over (order by points_allowed desc))::int as rank
    from totals
    order by rank;
$$;

-- 10. nfl_team_ranks_history: helper RPC that returns ranks-at-week ----------
-- Computes pass/rush offense + defense ranks from player_games up to the
-- given week. Used by sims to show "as-of week N" team strength.
create or replace function public.team_ranks_at_week(
    p_season int, p_up_to_week int
)
returns table (
    team text,
    pass_offense int, rush_offense int,
    pass_defense int, rush_defense int
)
language sql security definer set search_path = public as $$
    with off as (
        select
            pg.team,
            sum(pg.passing_yards)  as pass_yds_for,
            sum(pg.rushing_yards)  as rush_yds_for
        from public.player_games pg
        where pg.season = p_season and pg.week <= p_up_to_week
        group by pg.team
    ), def as (
        select
            pg.opponent as team,
            sum(pg.passing_yards) as pass_yds_against,
            sum(pg.rushing_yards) as rush_yds_against
        from public.player_games pg
        where pg.season = p_season and pg.week <= p_up_to_week
          and pg.opponent is not null and pg.opponent <> ''
        group by pg.opponent
    ), joined as (
        select
            coalesce(off.team, def.team) as team,
            off.pass_yds_for, off.rush_yds_for,
            def.pass_yds_against, def.rush_yds_against
        from off full outer join def on off.team = def.team
    )
    select
        team,
        (rank() over (order by pass_yds_for     desc nulls last))::int as pass_offense,
        (rank() over (order by rush_yds_for     desc nulls last))::int as rush_offense,
        (rank() over (order by pass_yds_against asc  nulls last))::int as pass_defense,
        (rank() over (order by rush_yds_against asc  nulls last))::int as rush_defense
    from joined
    where team is not null and team <> '';
$$;
