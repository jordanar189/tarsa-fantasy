-- Re-expand the plays table with the columns Game Center needs. The
-- earlier _plays_slim_ migration dropped these to save space; they're back
-- because the per-game Play-by-Play / Stats UI can't render meaningful
-- output without down/distance, score state, and play classification.
--
-- All columns nullable — historical rows that were synced under the slim
-- shape stay valid; only re-synced weeks will populate the new fields.

alter table public.plays
    add column if not exists qtr                    int,
    add column if not exists down                   int,
    add column if not exists ydstogo                int,
    add column if not exists yardline_100           int,
    add column if not exists posteam_score          int,
    add column if not exists defteam_score          int,
    add column if not exists game_seconds_remaining int,
    add column if not exists drive                  int,
    add column if not exists complete_pass          boolean,
    add column if not exists pass_attempt           boolean,
    add column if not exists rush_attempt           boolean,
    add column if not exists field_goal_attempt     boolean,
    add column if not exists field_goal_result      text,
    add column if not exists extra_point_attempt    boolean,
    add column if not exists extra_point_result     text,
    add column if not exists two_point_attempt      boolean,
    add column if not exists interception           boolean,
    add column if not exists fumble                 boolean,
    add column if not exists fumble_lost            boolean,
    add column if not exists first_down             boolean,
    add column if not exists sack                   boolean,
    add column if not exists penalty                boolean,
    add column if not exists penalty_yards          int,
    add column if not exists air_yards              numeric,
    add column if not exists yards_after_catch      numeric;

-- An index lets the Game Center fetch all plays for a game in O(log n).
create index if not exists plays_game_play_idx
    on public.plays (game_id, play_id);
