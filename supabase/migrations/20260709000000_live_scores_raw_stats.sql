-- Live scoring, part 2: raw counting stats + finals bookkeeping.
--
-- live_scores previously carried only the three precomputed preset point
-- fields. Two consequences: leagues with custom scoring_settings recompute
-- points from the RAW stat line client-side, so every player showed 0 live;
-- and kickers/defenses (whose points always derive from raw columns, never
-- the offense-only preset fields) showed 0 live in every league. The live
-- worker now syncs the same counting columns player_games carries, and the
-- client splices them into its cached Game rows.
--
-- espn_processed_games records finals the worker has already persisted, so
-- a completed game stops being re-fetched and re-churned through Realtime
-- every minute for the rest of the day.

alter table public.live_scores
    add column if not exists completions            numeric not null default 0,
    add column if not exists attempts               numeric not null default 0,
    add column if not exists passing_yards          numeric not null default 0,
    add column if not exists passing_tds            numeric not null default 0,
    add column if not exists passing_interceptions  numeric not null default 0,
    add column if not exists carries                numeric not null default 0,
    add column if not exists rushing_yards          numeric not null default 0,
    add column if not exists rushing_tds            numeric not null default 0,
    add column if not exists receptions             numeric not null default 0,
    add column if not exists targets                numeric not null default 0,
    add column if not exists receiving_yards        numeric not null default 0,
    add column if not exists receiving_tds          numeric not null default 0,
    add column if not exists fumbles_lost           numeric not null default 0,
    add column if not exists fg_made_0_19           numeric not null default 0,
    add column if not exists fg_made_20_29          numeric not null default 0,
    add column if not exists fg_made_30_39          numeric not null default 0,
    add column if not exists fg_made_40_49          numeric not null default 0,
    add column if not exists fg_made_50_59          numeric not null default 0,
    add column if not exists fg_made_60             numeric not null default 0,
    add column if not exists fg_missed              numeric not null default 0,
    add column if not exists pat_made               numeric not null default 0,
    add column if not exists pat_missed             numeric not null default 0,
    add column if not exists def_sacks              numeric not null default 0,
    add column if not exists def_interceptions      numeric not null default 0,
    add column if not exists def_fumble_recoveries  numeric not null default 0,
    add column if not exists def_tds                numeric not null default 0,
    add column if not exists def_safeties           numeric not null default 0,
    -- Non-null only on DEF_<TEAM> rows; also flags the row as a team defense.
    add column if not exists def_points_allowed     numeric;

create table if not exists public.espn_processed_games (
    event_id     text primary key,
    season       int not null,
    week         int not null,
    processed_at timestamptz not null default now()
);
-- Service-role only (worker bookkeeping; nothing client-facing).
alter table public.espn_processed_games enable row level security;
