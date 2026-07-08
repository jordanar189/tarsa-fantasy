-- Red-zone alert dedupe: one push per (game, drive). The insert is the
-- claim — the per-minute sync loses the PK race harmlessly on concurrent
-- runs. Rows are deleted when the game finalizes (sync_espn_live).

create table if not exists public.red_zone_alerts (
    event_id   text not null,           -- ESPN event id
    drive_id   text not null,
    created_at timestamptz not null default now(),
    primary key (event_id, drive_id)
);

-- Service-role only.
alter table public.red_zone_alerts enable row level security;
