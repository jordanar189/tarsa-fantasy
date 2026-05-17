-- Cached NFL data, mirrored from nflverse by the sync_nflverse Edge Function
-- and overlaid with in-game live scoring from sync_espn_live.

create table if not exists public.players_cache (
    id              text primary key,           -- nflverse GSIS player_id
    espn_id         text,                       -- for cross-referencing live ESPN scores
    name            text not null,
    position        text not null default '',
    position_group  text not null default '',
    team            text not null default '',
    headshot_url    text not null default '',
    updated_at      timestamptz not null default now()
);
create index if not exists players_cache_espn_idx on public.players_cache (espn_id);
create index if not exists players_cache_position_idx on public.players_cache (position);

create table if not exists public.player_games (
    player_id                 text not null references public.players_cache(id) on delete cascade,
    season                    int  not null,
    week                      int  not null,
    team                      text not null default '',
    opponent                  text not null default '',
    completions               numeric not null default 0,
    attempts                  numeric not null default 0,
    passing_yards             numeric not null default 0,
    passing_tds               numeric not null default 0,
    passing_interceptions     numeric not null default 0,
    carries                   numeric not null default 0,
    rushing_yards             numeric not null default 0,
    rushing_tds               numeric not null default 0,
    receptions                numeric not null default 0,
    targets                   numeric not null default 0,
    receiving_yards           numeric not null default 0,
    receiving_tds             numeric not null default 0,
    fumbles_lost              numeric not null default 0,
    fantasy_points            numeric not null default 0,
    fantasy_points_ppr        numeric not null default 0,
    fantasy_points_half_ppr   numeric not null default 0,
    updated_at                timestamptz not null default now(),
    primary key (player_id, season, week)
);
create index if not exists player_games_season_idx on public.player_games (season);
create index if not exists player_games_season_week_idx on public.player_games (season, week);

create table if not exists public.seasons (
    season          int primary key,
    games_count     int not null default 0,
    last_synced_at  timestamptz not null default now()
);

-- Live in-game scoring overlay. While a game is in progress, sync_espn_live
-- writes to this table; clients read player_games merged with live_scores
-- (live wins when present). When the game is final, the worker copies the
-- final numbers into player_games and clears the live row.
create table if not exists public.live_scores (
    player_id                 text not null,
    season                    int  not null,
    week                      int  not null,
    fantasy_points            numeric not null default 0,
    fantasy_points_ppr        numeric not null default 0,
    fantasy_points_half_ppr   numeric not null default 0,
    is_final                  boolean not null default false,
    updated_at                timestamptz not null default now(),
    primary key (player_id, season, week)
);
create index if not exists live_scores_season_week_idx on public.live_scores (season, week);

-- Row-level security: any authenticated user can read; writes go through the
-- service role key from Edge Functions (which bypasses RLS).
alter table public.players_cache enable row level security;
alter table public.player_games  enable row level security;
alter table public.seasons       enable row level security;
alter table public.live_scores   enable row level security;

drop policy if exists "players_cache_read" on public.players_cache;
drop policy if exists "player_games_read"  on public.player_games;
drop policy if exists "seasons_read"       on public.seasons;
drop policy if exists "live_scores_read"   on public.live_scores;

create policy "players_cache_read" on public.players_cache for select using (auth.role() = 'authenticated');
create policy "player_games_read"  on public.player_games  for select using (auth.role() = 'authenticated');
create policy "seasons_read"       on public.seasons       for select using (auth.role() = 'authenticated');
create policy "live_scores_read"   on public.live_scores   for select using (auth.role() = 'authenticated');

-- Enable Supabase Realtime on live_scores so clients can subscribe to score
-- changes during games. (Idempotent: drop & re-add if already present.)
do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'live_scores'
    ) then
        alter publication supabase_realtime drop table public.live_scores;
    end if;
    alter publication supabase_realtime add table public.live_scores;
end$$;
