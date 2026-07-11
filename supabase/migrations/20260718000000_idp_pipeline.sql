-- Individual defensive player (IDP) pipeline, part 1: storage.
--
-- player_games already carries def_sacks / def_interceptions /
-- def_fumble_recoveries / def_tds / def_safeties, but until now they were only
-- populated on the aggregated DEF_<TEAM> rows (zero on every individual row).
-- sync_nflverse now fills them per defender too, plus the tackle / pressure /
-- coverage counting stats below that only exist per player. Team-DST scoring
-- is unaffected: it keys off def_points_allowed, which stays null on player
-- rows. IDP scoring weights and lineup slots land in part 2.

alter table public.player_games
    add column if not exists def_tackles_solo      numeric not null default 0,
    add column if not exists def_tackle_assists    numeric not null default 0,
    add column if not exists def_tackles_for_loss  numeric not null default 0,
    add column if not exists def_qb_hits           numeric not null default 0,
    add column if not exists def_pass_defended     numeric not null default 0,
    add column if not exists def_fumbles_forced    numeric not null default 0;
