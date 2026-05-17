-- Slimmed-down play-by-play table. ~35 columns out of nflverse's ~370 —
-- enough for fantasy use cases (per-play scoring breakdown, drive analysis,
-- player involvement, EPA-aware research) without paying for the full data
-- shape. Populated by the sync_pbp Edge Function.
--
-- Storage budget: ~75 MB per season including indexes. The cron syncs only
-- the current + previous season by default; older seasons must be backfilled
-- manually via per-season POST.

create table if not exists public.plays (
    -- Identifiers
    game_id                  text not null,
    play_id                  int  not null,
    season                   int  not null,
    week                     int  not null,
    -- Teams
    home_team                text,
    away_team                text,
    posteam                  text,
    defteam                  text,
    -- Situation
    qtr                      int,
    game_seconds_remaining   int,
    down                     int,
    ydstogo                  int,
    yardline_100             int,
    posteam_score            int,
    defteam_score            int,
    -- Play meta
    play_type                text,
    description              text,
    -- Players (GSIS IDs, joinable to players_cache.id)
    passer_player_id         text,
    receiver_player_id       text,
    rusher_player_id         text,
    interception_player_id   text,
    sack_player_id           text,
    fumbled_1_player_id      text,
    td_player_id             text,
    -- Outcomes
    yards_gained             numeric,
    complete_pass            boolean,
    pass_attempt             boolean,
    rush_attempt             boolean,
    pass_touchdown           boolean,
    rush_touchdown           boolean,
    return_touchdown         boolean,
    interception             boolean,
    fumble                   boolean,
    fumble_lost              boolean,
    touchdown                boolean,
    two_point_attempt        boolean,
    extra_point_attempt      boolean,
    field_goal_attempt       boolean,
    field_goal_result        text,
    -- Advanced
    epa                      numeric,
    air_yards                numeric,
    yards_after_catch        numeric,
    success                  boolean,
    cpoe                     numeric,
    -- Metadata
    updated_at               timestamptz not null default now(),
    primary key (game_id, play_id)
);

create index if not exists plays_season_idx          on public.plays (season);
create index if not exists plays_season_week_idx     on public.plays (season, week);
create index if not exists plays_passer_idx          on public.plays (passer_player_id)   where passer_player_id   is not null;
create index if not exists plays_receiver_idx        on public.plays (receiver_player_id) where receiver_player_id is not null;
create index if not exists plays_rusher_idx          on public.plays (rusher_player_id)   where rusher_player_id   is not null;
create index if not exists plays_td_idx              on public.plays (td_player_id)       where td_player_id       is not null;
create index if not exists plays_play_type_idx       on public.plays (season, play_type);

alter table public.plays enable row level security;

drop policy if exists "plays_read" on public.plays;
create policy "plays_read" on public.plays for select using (auth.role() = 'authenticated');
