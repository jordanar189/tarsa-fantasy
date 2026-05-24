-- Kicker + team-defense (DST) scoring.
--
-- Before this, player_games only carried offensive counting stats, so the
-- precomputed nflverse fantasy_points was 0 for kickers (nflverse's figure is
-- offense-only) and team defenses had no game rows at all. Both showed 0.
--
-- This adds the raw kicking + defensive inputs the app needs to compute K/DST
-- points from the stat line (the same "score from raw stats" path the custom
-- league scoring already uses). sync_nflverse backfills these columns and
-- writes one aggregated DST row per team-week under the seeded DEF_<TEAM> id.

alter table public.player_games
    -- Kicking: made field goals bucketed by distance (distance-tiered scoring),
    -- plus extra points and misses.
    add column if not exists fg_made_0_19   numeric not null default 0,
    add column if not exists fg_made_20_29  numeric not null default 0,
    add column if not exists fg_made_30_39  numeric not null default 0,
    add column if not exists fg_made_40_49  numeric not null default 0,
    add column if not exists fg_made_50_59  numeric not null default 0,
    add column if not exists fg_made_60      numeric not null default 0,
    add column if not exists fg_missed       numeric not null default 0,
    add column if not exists pat_made        numeric not null default 0,
    add column if not exists pat_missed      numeric not null default 0,
    -- Team defense, aggregated across the team's players for the week.
    add column if not exists def_sacks              numeric not null default 0,
    add column if not exists def_interceptions      numeric not null default 0,
    add column if not exists def_fumble_recoveries  numeric not null default 0,
    add column if not exists def_tds                numeric not null default 0,
    add column if not exists def_safeties           numeric not null default 0,
    -- Points the defense allowed that week (opponent's final score). Nullable
    -- on purpose: only DST rows set it, and it's what flags a row as a team
    -- defense for the points-allowed tier bonus. NULL on every other row.
    add column if not exists def_points_allowed     numeric;
