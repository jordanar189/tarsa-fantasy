-- IDP part 3: live in-game defender stats.
--
-- live_scores gains the per-defender counting columns player_games already
-- carries, so sync_espn_live can stream the defensive box-score category and
-- individual defenders score live like everyone else. def_fumbles_forced is
-- included for column parity but stays 0 during games — ESPN's box score
-- doesn't carry forced fumbles; the nightly nflverse sync fills it in.

alter table public.live_scores
    add column if not exists def_tackles_solo      numeric not null default 0,
    add column if not exists def_tackle_assists    numeric not null default 0,
    add column if not exists def_tackles_for_loss  numeric not null default 0,
    add column if not exists def_qb_hits           numeric not null default 0,
    add column if not exists def_pass_defended     numeric not null default 0,
    add column if not exists def_fumbles_forced    numeric not null default 0;
