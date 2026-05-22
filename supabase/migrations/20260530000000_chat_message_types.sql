-- Structured chat messages: polls, pick'em, trivia, and trade-block cards.
--
-- 1. league_messages gains a `message_type` discriminator (default 'text', so
--    every existing row and any older client keeps working unchanged) and a
--    `payload` jsonb holding the type-specific data (question/options/etc).
-- 2. message_responses stores one row per (message, user) — a user's vote on a
--    poll/pick'em or answer to a trivia card. Mirrors league_message_reactions:
--    realtime fans out changes and clients aggregate the tallies. A user has at
--    most one response per message (re-voting upserts the choice).

-- --- 1. message_type + payload on league_messages ---------------------------

alter table public.league_messages
    add column if not exists message_type text not null default 'text',
    add column if not exists payload jsonb;

alter table public.league_messages
    drop constraint if exists league_messages_type_check;
alter table public.league_messages
    add constraint league_messages_type_check
    check (message_type in ('text', 'poll', 'pickem', 'trivia', 'tradeblock'));

-- Structured messages carry their content in `payload`, so the text/image
-- requirement only applies to plain 'text' messages.
alter table public.league_messages
    drop constraint if exists league_messages_content_check;
alter table public.league_messages
    add constraint league_messages_content_check
    check (
        message_type <> 'text'
        or image_url is not null
        or char_length(btrim(content)) between 1 and 2000
    );

-- Non-text messages must carry a payload.
alter table public.league_messages
    drop constraint if exists league_messages_payload_check;
alter table public.league_messages
    add constraint league_messages_payload_check
    check (message_type = 'text' or payload is not null);

-- --- 2. message_responses table ---------------------------------------------

create table if not exists public.message_responses (
    message_id  uuid not null references public.league_messages(id) on delete cascade,
    user_id     uuid not null references auth.users(id)            on delete cascade,
    choice      integer not null,
    created_at  timestamptz not null default now(),
    primary key (message_id, user_id)
);

create index if not exists message_responses_message_idx
    on public.message_responses (message_id);

alter table public.message_responses enable row level security;

drop policy if exists "message_responses_read"   on public.message_responses;
drop policy if exists "message_responses_insert" on public.message_responses;
drop policy if exists "message_responses_update" on public.message_responses;
drop policy if exists "message_responses_delete" on public.message_responses;

create policy "message_responses_read"
    on public.message_responses for select
    using (
        exists (
            select 1 from public.league_messages m
             where m.id = message_responses.message_id
               and public.is_league_member(m.league_id)
        )
    );

create policy "message_responses_insert"
    on public.message_responses for insert
    with check (
        user_id = auth.uid()
        and exists (
            select 1 from public.league_messages m
             where m.id = message_responses.message_id
               and public.is_league_member(m.league_id)
        )
    );

create policy "message_responses_update"
    on public.message_responses for update
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

create policy "message_responses_delete"
    on public.message_responses for delete
    using (user_id = auth.uid());

-- Realtime: publish response changes so all connected clients see vote tallies
-- update live. Mirrors the league_message_reactions publication.
do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'message_responses'
    ) then
        alter publication supabase_realtime drop table public.message_responses;
    end if;
    alter publication supabase_realtime add table public.message_responses;
end$$;
