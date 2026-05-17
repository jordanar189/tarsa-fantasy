-- Point spreads (per game) and offense/defense ranks (per team, cumulative)
-- sourced from MFL's nflSchedule endpoint via sync_mfl. Plus most_started %
-- from topStarters.

-- 1. Spreads belong on the game row. Convention: negative when home is favored
--    (matches MFL). Nullable so off-season / undated games stay clean.
alter table public.nfl_schedules
    add column if not exists home_spread numeric;

-- 2. Per-team rolling ranks (offense/defense, pass/rush). Each team has one
--    row that gets overwritten on every sync — these are cumulative current
--    ranks, not snapshots in time.
create table if not exists public.nfl_team_ranks (
    team             text primary key,
    pass_offense     int,
    rush_offense     int,
    pass_defense     int,
    rush_defense     int,
    updated_at       timestamptz not null default now()
);

alter table public.nfl_team_ranks enable row level security;
drop policy if exists "team_ranks_read" on public.nfl_team_ranks;
create policy "team_ranks_read" on public.nfl_team_ranks
    for select using (auth.role() = 'authenticated');

-- 3. Most-started % from MFL's topStarters. Truncate+insert on each sync.
create table if not exists public.most_started (
    player_id     text primary key,
    started_pct   numeric not null,
    updated_at    timestamptz not null default now()
);
create index if not exists most_started_pct_idx
    on public.most_started (started_pct desc);

alter table public.most_started enable row level security;
drop policy if exists "most_started_read" on public.most_started;
create policy "most_started_read" on public.most_started
    for select using (auth.role() = 'authenticated');
