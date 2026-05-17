-- Social layer: friendships and direct messaging.
--
-- Friendships are stored canonically (user_a < user_b) so each pair has at
-- most one row. Status pending until the recipient accepts; declining or
-- unfriending is just a DELETE.
--
-- DMs live in dm_threads (one per pair, also canonically ordered) +
-- dm_messages. Realtime is published on dm_messages so a chat view inside
-- an open thread updates live.
--
-- Image attachments use the dm-images storage bucket, namespaced by
-- thread_id so the RLS policy can gate writes to thread participants.

-- ---------------------------------------------------------------------------
-- 1. Friendships
-- ---------------------------------------------------------------------------

create table if not exists public.friendships (
    user_a        uuid not null references auth.users(id) on delete cascade,
    user_b        uuid not null references auth.users(id) on delete cascade,
    requested_by  uuid not null references auth.users(id) on delete cascade,
    status        text not null default 'pending'
                  check (status in ('pending', 'accepted')),
    created_at    timestamptz not null default now(),
    accepted_at   timestamptz,
    primary key (user_a, user_b),
    check (user_a < user_b)
);

create index if not exists friendships_user_a_idx on public.friendships (user_a);
create index if not exists friendships_user_b_idx on public.friendships (user_b);

alter table public.friendships enable row level security;

drop policy if exists "friendships_read"   on public.friendships;
drop policy if exists "friendships_insert" on public.friendships;
drop policy if exists "friendships_update" on public.friendships;
drop policy if exists "friendships_delete" on public.friendships;

create policy "friendships_read"
    on public.friendships for select
    using (auth.uid() in (user_a, user_b));

create policy "friendships_insert"
    on public.friendships for insert
    with check (
        requested_by = auth.uid()
        and auth.uid() in (user_a, user_b)
        and status = 'pending'
    );

-- Only the recipient (not the requester) can accept a pending row.
create policy "friendships_update"
    on public.friendships for update
    using (
        auth.uid() in (user_a, user_b)
        and auth.uid() <> requested_by
        and status = 'pending'
    )
    with check (status = 'accepted');

create policy "friendships_delete"
    on public.friendships for delete
    using (auth.uid() in (user_a, user_b));

-- send_friend_request: insert canonically; idempotent if a row already exists.
create or replace function public.send_friend_request(p_other_user uuid)
returns public.friendships
language plpgsql security definer set search_path = public, auth
as $$
declare
    me uuid := auth.uid();
    ua uuid;
    ub uuid;
    row public.friendships;
begin
    if me is null then raise exception 'unauthenticated'; end if;
    if me = p_other_user then raise exception 'cannot friend self'; end if;

    if me < p_other_user then
        ua := me; ub := p_other_user;
    else
        ua := p_other_user; ub := me;
    end if;

    insert into public.friendships (user_a, user_b, requested_by, status)
        values (ua, ub, me, 'pending')
        on conflict (user_a, user_b) do nothing
        returning * into row;

    if row.user_a is null then
        select * into row from public.friendships
         where user_a = ua and user_b = ub;
    end if;
    return row;
end$$;

grant execute on function public.send_friend_request(uuid) to authenticated;

-- accept_friend_request: only succeeds on a pending row the caller didn't send.
create or replace function public.accept_friend_request(p_other_user uuid)
returns public.friendships
language plpgsql security definer set search_path = public, auth
as $$
declare
    me uuid := auth.uid();
    ua uuid;
    ub uuid;
    row public.friendships;
begin
    if me is null then raise exception 'unauthenticated'; end if;
    if me < p_other_user then
        ua := me; ub := p_other_user;
    else
        ua := p_other_user; ub := me;
    end if;

    update public.friendships
       set status = 'accepted', accepted_at = now()
     where user_a = ua and user_b = ub
       and status = 'pending'
       and requested_by <> me
    returning * into row;

    if row.user_a is null then raise exception 'no pending request to accept'; end if;
    return row;
end$$;

grant execute on function public.accept_friend_request(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. DM threads + messages
-- ---------------------------------------------------------------------------

create table if not exists public.dm_threads (
    id              uuid primary key default gen_random_uuid(),
    user_a          uuid not null references auth.users(id) on delete cascade,
    user_b          uuid not null references auth.users(id) on delete cascade,
    created_at      timestamptz not null default now(),
    last_message_at timestamptz,
    check (user_a < user_b),
    unique (user_a, user_b)
);

create index if not exists dm_threads_user_a_idx on public.dm_threads (user_a);
create index if not exists dm_threads_user_b_idx on public.dm_threads (user_b);

alter table public.dm_threads enable row level security;

drop policy if exists "dm_threads_read"   on public.dm_threads;
drop policy if exists "dm_threads_insert" on public.dm_threads;

create policy "dm_threads_read"
    on public.dm_threads for select
    using (auth.uid() in (user_a, user_b));

create policy "dm_threads_insert"
    on public.dm_threads for insert
    with check (auth.uid() in (user_a, user_b));

create table if not exists public.dm_messages (
    id          uuid primary key default gen_random_uuid(),
    thread_id   uuid not null references public.dm_threads(id) on delete cascade,
    sender_id   uuid not null references auth.users(id)        on delete cascade,
    content     text not null default '',
    image_url   text,
    created_at  timestamptz not null default now(),
    check (image_url is not null or char_length(btrim(content)) between 1 and 2000)
);

create index if not exists dm_messages_thread_time_idx
    on public.dm_messages (thread_id, created_at);

alter table public.dm_messages enable row level security;

create or replace function public.is_dm_participant(p_thread_id uuid)
returns boolean
language sql stable security definer set search_path = public, auth as $$
    select exists (
        select 1 from public.dm_threads t
         where t.id = p_thread_id
           and auth.uid() in (t.user_a, t.user_b)
    );
$$;

grant execute on function public.is_dm_participant(uuid) to authenticated;

drop policy if exists "dm_messages_read"   on public.dm_messages;
drop policy if exists "dm_messages_insert" on public.dm_messages;
drop policy if exists "dm_messages_delete" on public.dm_messages;

create policy "dm_messages_read"
    on public.dm_messages for select
    using (public.is_dm_participant(thread_id));

create policy "dm_messages_insert"
    on public.dm_messages for insert
    with check (
        sender_id = auth.uid()
        and public.is_dm_participant(thread_id)
    );

create policy "dm_messages_delete"
    on public.dm_messages for delete
    using (sender_id = auth.uid());

-- get_or_create_dm_thread: pair-canonicalized upsert; returns the row.
create or replace function public.get_or_create_dm_thread(p_other_user uuid)
returns public.dm_threads
language plpgsql security definer set search_path = public, auth
as $$
declare
    me uuid := auth.uid();
    ua uuid;
    ub uuid;
    row public.dm_threads;
begin
    if me is null then raise exception 'unauthenticated'; end if;
    if me = p_other_user then raise exception 'cannot DM self'; end if;

    if me < p_other_user then ua := me; ub := p_other_user;
    else                       ua := p_other_user; ub := me;
    end if;

    insert into public.dm_threads (user_a, user_b)
        values (ua, ub)
        on conflict (user_a, user_b) do nothing
        returning * into row;

    if row.id is null then
        select * into row from public.dm_threads where user_a = ua and user_b = ub;
    end if;
    return row;
end$$;

grant execute on function public.get_or_create_dm_thread(uuid) to authenticated;

-- Trigger: bump dm_threads.last_message_at when a new message lands so the
-- inbox list can sort by recency without scanning dm_messages.
create or replace function public.bump_dm_thread_last_message()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    update public.dm_threads
       set last_message_at = new.created_at
     where id = new.thread_id;
    return new;
end$$;

drop trigger if exists dm_messages_bump_thread on public.dm_messages;
create trigger dm_messages_bump_thread
    after insert on public.dm_messages
    for each row execute function public.bump_dm_thread_last_message();

-- ---------------------------------------------------------------------------
-- 3. DM image storage
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
    values ('dm-images', 'dm-images', true)
    on conflict (id) do nothing;

drop policy if exists "dm_images_upload" on storage.objects;
create policy "dm_images_upload"
    on storage.objects for insert
    with check (
        bucket_id = 'dm-images'
        and auth.role() = 'authenticated'
        and public.is_dm_participant(
            ((storage.foldername(name))[1])::uuid
        )
    );

drop policy if exists "dm_images_read" on storage.objects;
create policy "dm_images_read"
    on storage.objects for select
    using (bucket_id = 'dm-images');

-- ---------------------------------------------------------------------------
-- 4. Realtime
-- ---------------------------------------------------------------------------

do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'dm_messages'
    ) then
        alter publication supabase_realtime drop table public.dm_messages;
    end if;
    alter publication supabase_realtime add table public.dm_messages;

    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'friendships'
    ) then
        alter publication supabase_realtime drop table public.friendships;
    end if;
    alter publication supabase_realtime add table public.friendships;
end$$;
