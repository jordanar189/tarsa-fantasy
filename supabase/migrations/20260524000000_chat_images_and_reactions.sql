-- Chat enhancements: image attachments and emoji reactions.
--
-- 1. league_messages gains an optional image_url column. The content check is
--    relaxed so a message can be image-only (empty text + non-null image_url).
-- 2. A public storage bucket `chat-images` holds the uploaded files. Paths
--    are namespaced by league_id so the RLS policy can gate uploads to that
--    league's members.
-- 3. league_message_reactions stores Slack-style reactions: one row per
--    (message, user, emoji), so a user can react with multiple distinct
--    emojis on the same message but only one of each.

-- --- 1. image_url column on league_messages ----------------------------------

alter table public.league_messages
    add column if not exists image_url text;

alter table public.league_messages
    drop constraint if exists league_messages_content_check;

alter table public.league_messages
    add constraint league_messages_content_check
    check (
        image_url is not null
        or char_length(btrim(content)) between 1 and 2000
    );

-- --- 2. chat-images storage bucket ------------------------------------------

insert into storage.buckets (id, name, public)
    values ('chat-images', 'chat-images', true)
    on conflict (id) do nothing;

drop policy if exists "chat_images_upload" on storage.objects;
create policy "chat_images_upload"
    on storage.objects for insert
    with check (
        bucket_id = 'chat-images'
        and auth.role() = 'authenticated'
        and public.is_league_member(
            ((storage.foldername(name))[1])::uuid
        )
    );

drop policy if exists "chat_images_read" on storage.objects;
create policy "chat_images_read"
    on storage.objects for select
    using (bucket_id = 'chat-images');

-- --- 3. league_message_reactions table --------------------------------------

create table if not exists public.league_message_reactions (
    message_id  uuid not null references public.league_messages(id) on delete cascade,
    user_id     uuid not null references auth.users(id)            on delete cascade,
    emoji       text not null check (char_length(emoji) between 1 and 16),
    created_at  timestamptz not null default now(),
    primary key (message_id, user_id, emoji)
);

create index if not exists league_message_reactions_message_idx
    on public.league_message_reactions (message_id);

alter table public.league_message_reactions enable row level security;

drop policy if exists "league_reactions_read"   on public.league_message_reactions;
drop policy if exists "league_reactions_insert" on public.league_message_reactions;
drop policy if exists "league_reactions_delete" on public.league_message_reactions;

create policy "league_reactions_read"
    on public.league_message_reactions for select
    using (
        exists (
            select 1 from public.league_messages m
             where m.id = league_message_reactions.message_id
               and public.is_league_member(m.league_id)
        )
    );

create policy "league_reactions_insert"
    on public.league_message_reactions for insert
    with check (
        user_id = auth.uid()
        and exists (
            select 1 from public.league_messages m
             where m.id = league_message_reactions.message_id
               and public.is_league_member(m.league_id)
        )
    );

create policy "league_reactions_delete"
    on public.league_message_reactions for delete
    using (user_id = auth.uid());

-- Realtime: publish reaction changes so all connected clients see new/removed
-- reactions instantly. Mirrors the league_messages publication.
do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'league_message_reactions'
    ) then
        alter publication supabase_realtime drop table public.league_message_reactions;
    end if;
    alter publication supabase_realtime add table public.league_message_reactions;
end$$;
