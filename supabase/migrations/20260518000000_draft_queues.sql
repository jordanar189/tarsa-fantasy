-- Personal draft queue. Each team can queue an ordered list of players;
-- when their auto-pick fires, the queue is consumed (top entry whose
-- player is still available) before the loop-strategy fallback runs.
--
-- One row per (draft_id, team_id, position) — position is the 1-indexed
-- spot in the queue. Reorder writes shift the position values en masse.

create table if not exists public.draft_queues (
    draft_id   uuid not null references public.drafts(id) on delete cascade,
    team_id    uuid not null references public.teams(id)  on delete cascade,
    position   int  not null,
    player_id  text not null,
    added_at   timestamptz not null default now(),
    primary key (draft_id, team_id, position),
    unique (draft_id, team_id, player_id)
);
create index if not exists draft_queues_team_idx
    on public.draft_queues (draft_id, team_id, position);

alter table public.draft_queues enable row level security;

-- Read: anyone in the league (for client UI). Writes restricted to the
-- team owner (via RPCs below; direct writes blocked).
drop policy if exists "draft_queues_read" on public.draft_queues;
create policy "draft_queues_read"
    on public.draft_queues for select using (auth.role() = 'authenticated');

-- RPC: append a player to the team owner's queue. Idempotent — if the
-- player is already queued, returns silently.
create or replace function public.queue_add(
    p_draft_id uuid, p_team_id uuid, p_player_id text
) returns int
language plpgsql security definer set search_path = public as $$
declare
    is_owner   boolean;
    next_pos   int;
begin
    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    if coalesce(is_owner, false) is false then
        raise exception 'not authorized to manage this team''s queue';
    end if;

    if exists (
        select 1 from public.draft_queues
         where draft_id = p_draft_id and team_id = p_team_id
           and player_id = p_player_id
    ) then
        return null;
    end if;

    select coalesce(max(position), 0) + 1 into next_pos
      from public.draft_queues
     where draft_id = p_draft_id and team_id = p_team_id;

    insert into public.draft_queues (draft_id, team_id, position, player_id)
    values (p_draft_id, p_team_id, next_pos, p_player_id);
    return next_pos;
end$$;

-- RPC: remove a queued player. Compacts subsequent positions.
create or replace function public.queue_remove(
    p_draft_id uuid, p_team_id uuid, p_player_id text
) returns void
language plpgsql security definer set search_path = public as $$
declare
    is_owner boolean;
    removed_pos int;
begin
    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    if coalesce(is_owner, false) is false then
        raise exception 'not authorized to manage this team''s queue';
    end if;

    delete from public.draft_queues
     where draft_id = p_draft_id and team_id = p_team_id
       and player_id = p_player_id
     returning position into removed_pos;

    if removed_pos is not null then
        update public.draft_queues
           set position = position - 1
         where draft_id = p_draft_id and team_id = p_team_id
           and position > removed_pos;
    end if;
end$$;

-- RPC: replace the entire queue with the provided ordered list.
-- Atomic — clears existing rows and re-inserts in order.
create or replace function public.queue_reorder(
    p_draft_id uuid, p_team_id uuid, p_player_ids text[]
) returns void
language plpgsql security definer set search_path = public as $$
declare
    is_owner boolean;
    i        int;
begin
    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    if coalesce(is_owner, false) is false then
        raise exception 'not authorized to manage this team''s queue';
    end if;

    delete from public.draft_queues
     where draft_id = p_draft_id and team_id = p_team_id;

    if p_player_ids is null or array_length(p_player_ids, 1) is null then
        return;
    end if;
    for i in 1 .. array_length(p_player_ids, 1) loop
        insert into public.draft_queues (draft_id, team_id, position, player_id)
        values (p_draft_id, p_team_id, i, p_player_ids[i]);
    end loop;
end$$;

-- Realtime publication so other devices owned by the same user (or
-- spectators) see queue changes live.
do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'draft_queues'
    ) then
        alter publication supabase_realtime drop table public.draft_queues;
    end if;
    alter publication supabase_realtime add table public.draft_queues;
end$$;
