-- Chat cards v2: drop trivia, support multi-pick responses, and let members
-- append options to a poll.
--
-- 1. Trivia is removed from the product. Delete any trivia cards (cascades to
--    their responses) and tighten the message_type check to the live set.
-- 2. message_responses gains a `slot` so one card can hold several questions —
--    a pick'em has one slot per game, a multi-select poll one slot per chosen
--    option. The primary key widens to (message_id, user_id, slot).
-- 3. append_poll_option lets any league member add an option to a poll that
--    opted in (payload.allowAddOptions), via a validated SECURITY DEFINER
--    function rather than a broad UPDATE policy. The resulting league_messages
--    UPDATE fans out over realtime so every client sees the new option.

-- --- 1. remove trivia --------------------------------------------------------

delete from public.league_messages where message_type = 'trivia';

alter table public.league_messages
    drop constraint if exists league_messages_type_check;
alter table public.league_messages
    add constraint league_messages_type_check
    check (message_type in ('text', 'poll', 'pickem', 'tradeblock'));

-- --- 2. slot dimension on message_responses ----------------------------------

alter table public.message_responses
    add column if not exists slot integer not null default 0;

alter table public.message_responses
    drop constraint if exists message_responses_pkey;
alter table public.message_responses
    add constraint message_responses_pkey primary key (message_id, user_id, slot);

-- --- 3. append_poll_option ---------------------------------------------------

create or replace function public.append_poll_option(
    p_message_id uuid,
    p_option     text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_league  uuid;
    v_type    text;
    v_payload jsonb;
    v_clean   text;
    v_count   int;
begin
    select league_id, message_type, payload
      into v_league, v_type, v_payload
      from public.league_messages
     where id = p_message_id;

    if v_league is null then
        raise exception 'message not found';
    end if;
    if not public.is_league_member(v_league) then
        raise exception 'not a league member';
    end if;
    if v_type <> 'poll' then
        raise exception 'message is not a poll';
    end if;
    if coalesce((v_payload->>'allowAddOptions')::boolean, false) is not true then
        raise exception 'this poll does not allow added options';
    end if;

    v_clean := btrim(coalesce(p_option, ''));
    if char_length(v_clean) = 0 or char_length(v_clean) > 80 then
        raise exception 'invalid option';
    end if;

    -- Drop silently on case-insensitive duplicates so a double-tap is a no-op.
    if exists (
        select 1
          from jsonb_array_elements_text(coalesce(v_payload->'options', '[]'::jsonb)) o
         where lower(o) = lower(v_clean)
    ) then
        return;
    end if;

    select jsonb_array_length(coalesce(v_payload->'options', '[]'::jsonb)) into v_count;
    if v_count >= 12 then
        raise exception 'poll already has the maximum number of options';
    end if;

    update public.league_messages
       set payload = jsonb_set(
               coalesce(payload, '{}'::jsonb),
               '{options}',
               coalesce(payload->'options', '[]'::jsonb) || to_jsonb(v_clean)
           )
     where id = p_message_id;
end;
$$;

grant execute on function public.append_poll_option(uuid, text) to authenticated;
