-- Trim plays table to the 15 most useful columns. The original 45-column
-- shape made each Edge Function invocation more expensive than necessary;
-- this slimmer schema cuts both per-row projection work and per-upsert
-- payload size. Future expansion: add columns back with new migrations as
-- specific features need them.

-- Drop indexes that reference columns we're removing.
drop index if exists public.plays_play_type_idx;

-- Drop the unused columns.
alter table public.plays drop column if exists home_team;
alter table public.plays drop column if exists away_team;
alter table public.plays drop column if exists qtr;
alter table public.plays drop column if exists game_seconds_remaining;
alter table public.plays drop column if exists down;
alter table public.plays drop column if exists ydstogo;
alter table public.plays drop column if exists yardline_100;
alter table public.plays drop column if exists posteam_score;
alter table public.plays drop column if exists defteam_score;
alter table public.plays drop column if exists interception_player_id;
alter table public.plays drop column if exists sack_player_id;
alter table public.plays drop column if exists fumbled_1_player_id;
alter table public.plays drop column if exists complete_pass;
alter table public.plays drop column if exists pass_attempt;
alter table public.plays drop column if exists rush_attempt;
alter table public.plays drop column if exists pass_touchdown;
alter table public.plays drop column if exists rush_touchdown;
alter table public.plays drop column if exists return_touchdown;
alter table public.plays drop column if exists interception;
alter table public.plays drop column if exists fumble;
alter table public.plays drop column if exists fumble_lost;
alter table public.plays drop column if exists two_point_attempt;
alter table public.plays drop column if exists extra_point_attempt;
alter table public.plays drop column if exists field_goal_attempt;
alter table public.plays drop column if exists field_goal_result;
alter table public.plays drop column if exists air_yards;
alter table public.plays drop column if exists yards_after_catch;
alter table public.plays drop column if exists success;
alter table public.plays drop column if exists cpoe;

-- Re-create the play_type index (was joint with season; now solo since we
-- still benefit from filtering plays by type within a season).
create index if not exists plays_play_type_idx on public.plays (season, play_type);

-- Surviving columns (15 + 2 metadata):
--   game_id, play_id, season, week
--   posteam, defteam
--   play_type, description
--   passer_player_id, receiver_player_id, rusher_player_id, td_player_id
--   yards_gained, touchdown, epa
--   updated_at, (primary key game_id+play_id)
