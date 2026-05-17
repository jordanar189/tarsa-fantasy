-- League-scoped live chat. One row per posted message; realtime publishes
-- INSERTs so every connected leaguemate sees new messages instantly.
--
-- Access is gated on team membership in the league. The commissioner is
-- always a member by virtue of owning the league row; other members are
-- whoever owns a team in public.teams. RLS enforces this for both reads
-- and writes.

create table if not exists public.league_messages (
    id          uuid primary key default gen_random_uuid(),
    league_id   uuid not null references public.leagues(id) on delete cascade,
    user_id     uuid not null references auth.users(id)     on delete cascade,
    content     text not null
        check (char_length(btrim(content)) between 1 and 2000),
    created_at  timestamptz not null default now()
);
create index if not exists league_messages_league_time_idx
    on public.league_messages (league_id, created_at);

alter table public.league_messages enable row level security;

-- Member predicate: caller owns a team in this league OR is the commish.
-- Reused for both select and insert policies.
create or replace function public.is_league_member(p_league_id uuid)
returns boolean
language sql security definer set search_path = public, auth as $$
    select exists (
        select 1 from public.teams t
         where t.league_id = p_league_id and t.owner_id = auth.uid()
    ) or exists (
        select 1 from public.leagues l
         where l.id = p_league_id and l.creator_id = auth.uid()
    );
$$;

drop policy if exists "league_messages_read"   on public.league_messages;
drop policy if exists "league_messages_insert" on public.league_messages;
drop policy if exists "league_messages_delete" on public.league_messages;

create policy "league_messages_read"
    on public.league_messages for select
    using (public.is_league_member(league_id));

create policy "league_messages_insert"
    on public.league_messages for insert
    with check (
        user_id = auth.uid()
        and public.is_league_member(league_id)
    );

-- Authors can delete their own messages; commissioners can moderate any.
create policy "league_messages_delete"
    on public.league_messages for delete
    using (
        user_id = auth.uid()
        or exists (
            select 1 from public.leagues l
             where l.id = league_messages.league_id and l.creator_id = auth.uid()
        )
    );

-- Realtime: publish INSERT/UPDATE/DELETE so connected clients update live.
do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'league_messages'
    ) then
        alter publication supabase_realtime drop table public.league_messages;
    end if;
    alter publication supabase_realtime add table public.league_messages;
end$$;
