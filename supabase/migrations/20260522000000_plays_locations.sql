-- Per-play directional metadata for the Gamecast field renderer. Sharpens
-- arrow placement: pass plays can show the ball travelling to the correct
-- third of the field; run plays can show which gap was attacked.
--
-- All nullable; historical rows synced before this migration stay valid
-- (the renderer falls back to a centered straight arrow).

alter table public.plays
    add column if not exists pass_location text,   -- 'left' | 'middle' | 'right'
    add column if not exists run_location  text,   -- 'left' | 'middle' | 'right'
    add column if not exists run_gap       text;   -- 'end' | 'tackle' | 'guard'
