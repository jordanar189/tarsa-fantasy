-- Per-season average draft position, sourced from Fantasy Football Calculator
-- (FFC) via the sync_adp Edge Function. One row per (season, scoring, player).
-- player_id is the nflverse ID, resolved from FFC's player by name+position+
-- team match against players_cache at sync time.
create table if not exists public.adp (
    season        int  not null,
    scoring       text not null,  -- 'standard' | 'ppr' | 'half'
    player_id     text not null,
    adp           numeric not null,
    times_drafted int,
    high          int,
    low           int,
    stdev         numeric,
    updated_at    timestamptz not null default now(),
    primary key (season, scoring, player_id)
);
create index if not exists adp_season_scoring_idx
    on public.adp (season, scoring, adp);

alter table public.adp enable row level security;
drop policy if exists "adp_read" on public.adp;
create policy "adp_read" on public.adp
    for select using (auth.role() = 'authenticated');
