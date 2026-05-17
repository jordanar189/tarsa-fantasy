-- Move trending from a SQL aggregate (over our own users' transactions) to
-- a snapshot table populated from MFL's market-wide topAdds/topDrops feeds.
-- The old function returned ints (counts); the new table stores percentages
-- (% of MFL leagues that added/dropped in the last day) which scales
-- independently of our user base.

drop function if exists public.trending_players(int);

create table if not exists public.trending_players (
    player_id   text primary key,
    adds_pct    numeric not null default 0,   -- % of leagues that added
    drops_pct   numeric not null default 0,   -- % of leagues that dropped
    updated_at  timestamptz not null default now()
);
create index if not exists trending_adds_idx  on public.trending_players (adds_pct  desc);
create index if not exists trending_drops_idx on public.trending_players (drops_pct desc);

alter table public.trending_players enable row level security;
drop policy if exists "trending_read" on public.trending_players;
create policy "trending_read" on public.trending_players
    for select using (auth.role() = 'authenticated');
