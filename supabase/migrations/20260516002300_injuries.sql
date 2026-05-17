-- Current injury status per player, sourced from MFL's injuries endpoint
-- via sync_mfl. One row per injured player; healthy players have no row.
-- Truncated and rewritten on each sync — MFL gives a complete snapshot.
create table if not exists public.injuries (
    player_id        text primary key,
    status           text not null,        -- 'Out', 'Questionable', 'Doubtful', 'IR', etc.
    details          text,                 -- e.g., 'Knee - ACL'
    expected_return  date,
    updated_at       timestamptz not null default now()
);
create index if not exists injuries_status_idx on public.injuries (status);

alter table public.injuries enable row level security;
drop policy if exists "injuries_read" on public.injuries;
create policy "injuries_read" on public.injuries
    for select using (auth.role() = 'authenticated');
