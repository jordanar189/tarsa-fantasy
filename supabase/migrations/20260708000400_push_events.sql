-- Event-driven push notifications.
--
-- The existing push stack (push_notifications + send_push) is an
-- admin-broadcast composer only — nothing notified users about the things
-- that actually happen to them. This adds a per-user outbox (push_events)
-- drained by the same per-minute send_push cron, and trigger-based producers
-- for the first event set: trade offers/outcomes, waiver wins/losses, and
-- draft start / on-the-clock. Triggers (rather than edits to each RPC) catch
-- every write path — client RPCs, edge-function workers, and commish tools.
-- Simulation (is_test) leagues never notify: bots would spam their owner.

create table if not exists public.push_events (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references public.profiles(id) on delete cascade,
    title      text not null,
    body       text not null,
    deep_link  text,
    created_at timestamptz not null default now(),
    sent_at    timestamptz,
    error      text
);
create index if not exists push_events_unsent_idx
    on public.push_events (created_at) where sent_at is null;

-- Service-role only: no client-facing policies at all.
alter table public.push_events enable row level security;

-- Atomically claim a batch for delivery (send_push drains this every
-- minute). Claiming marks sent_at up front: a crash between claim and APNs
-- delivery drops that batch (at-most-once), which is the right trade-off
-- for alerts — duplicates annoy, one missed alert doesn't.
create or replace function public.claim_push_events(p_limit int default 200)
returns setof public.push_events
language plpgsql security definer set search_path = public as $$
begin
    return query
    update public.push_events e
       set sent_at = now()
     where e.id in (
        select id from public.push_events
         where sent_at is null
           and created_at > now() - interval '1 day'
         order by created_at
         limit p_limit
         for update skip locked
     )
    returning e.*;
end$$;

create or replace function public.queue_push(
    p_user uuid, p_title text, p_body text, p_deep_link text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
    if p_user is null then return; end if;
    insert into public.push_events (user_id, title, body, deep_link)
    values (p_user, p_title, p_body, p_deep_link);
end$$;

-- Both helpers bypass push_events RLS via security definer, so clients must
-- not be able to reach them through /rest/v1/rpc: queue_push would let any
-- authenticated user spam arbitrary notifications at any user, and
-- claim_push_events would let one drain (and silence) the whole outbox.
-- Triggers still call queue_push fine (definer functions run as the owner),
-- and send_push keeps claim_push_events via its service-role grant.
revoke execute on function public.queue_push(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.claim_push_events(int) from public, anon, authenticated;
grant execute on function public.claim_push_events(int) to service_role;

create or replace function public.player_display_name(p_id text) returns text
language sql stable security definer set search_path = public as $$
    select coalesce((select name from public.players_cache where id = p_id), p_id)
$$;

create or replace function public.league_is_test(p_league_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
    select coalesce((select is_test from public.leagues where id = p_league_id), false)
$$;

-- ---- Trades ---------------------------------------------------------------

create or replace function public.notify_trade_created() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    recipient_owner uuid;
    proposer_name   text;
begin
    if public.league_is_test(new.league_id) then return new; end if;
    if new.status <> 'pending' then return new; end if;
    select owner_id into recipient_owner from public.teams where id = new.recipient_team_id;
    select name into proposer_name from public.teams where id = new.proposer_team_id;
    perform public.queue_push(
        recipient_owner,
        'New trade offer',
        coalesce(proposer_name, 'A team') || ' sent you a trade offer.',
        'tarsafantasy://league/' || new.league_id
    );
    return new;
end$$;

drop trigger if exists trades_notify_created on public.trades;
create trigger trades_notify_created
    after insert on public.trades
    for each row execute function public.notify_trade_created();

create or replace function public.notify_trade_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    proposer_owner  uuid;
    recipient_owner uuid;
    proposer_name   text;
    recipient_name  text;
    link            text;
begin
    if public.league_is_test(new.league_id) then return new; end if;
    if new.status is not distinct from old.status then return new; end if;

    select owner_id, name into proposer_owner,  proposer_name
      from public.teams where id = new.proposer_team_id;
    select owner_id, name into recipient_owner, recipient_name
      from public.teams where id = new.recipient_team_id;
    link := 'tarsafantasy://league/' || new.league_id;

    if new.status = 'rejected' and old.status = 'pending' then
        perform public.queue_push(proposer_owner, 'Trade declined',
            coalesce(recipient_name, 'The other team') || ' declined your trade offer.', link);
    elsif new.status in ('accepted', 'pending_execution', 'pending_approval', 'voting')
          and old.status = 'pending' then
        perform public.queue_push(proposer_owner, 'Trade accepted',
            coalesce(recipient_name, 'The other team') || ' accepted your trade offer'
            || case when new.status in ('pending_approval', 'voting')
                    then ' — pending league review.' else '.' end,
            link);
    elsif new.status = 'vetoed' then
        perform public.queue_push(proposer_owner, 'Trade vetoed',
            'Your trade with ' || coalesce(recipient_name, 'the other team') || ' was vetoed.', link);
        perform public.queue_push(recipient_owner, 'Trade vetoed',
            'Your trade with ' || coalesce(proposer_name, 'the other team') || ' was vetoed.', link);
    elsif new.status = 'executed' then
        perform public.queue_push(proposer_owner, 'Trade processed',
            'Your trade with ' || coalesce(recipient_name, 'the other team') || ' is complete.', link);
        perform public.queue_push(recipient_owner, 'Trade processed',
            'Your trade with ' || coalesce(proposer_name, 'the other team') || ' is complete.', link);
    end if;
    return new;
end$$;

drop trigger if exists trades_notify_status on public.trades;
create trigger trades_notify_status
    after update on public.trades
    for each row execute function public.notify_trade_status();

-- ---- Waivers --------------------------------------------------------------

-- Wins surface via the transaction the worker logs (covers both immediate
-- and held-for-approval wins).
create or replace function public.notify_waiver_won() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    team_owner uuid;
begin
    if new.kind <> 'waiver_claim' then return new; end if;
    if public.league_is_test(new.league_id) then return new; end if;
    select owner_id into team_owner from public.teams where id = new.team_id;
    perform public.queue_push(
        team_owner,
        'Waiver claim won',
        'You won ' || public.player_display_name(new.add_player_id)
        || case when new.bid is not null then ' for $' || new.bid else '' end
        || case when new.status = 'pending_approval'
                then ' — pending commissioner approval.' else '.' end,
        'tarsafantasy://league/' || new.league_id
    );
    return new;
end$$;

drop trigger if exists transactions_notify_waiver_won on public.transactions;
create trigger transactions_notify_waiver_won
    after insert on public.transactions
    for each row execute function public.notify_waiver_won();

create or replace function public.notify_waiver_lost() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    team_owner uuid;
begin
    if new.status <> 'failed' or old.status = 'failed' then return new; end if;
    if public.league_is_test(new.league_id) then return new; end if;
    select owner_id into team_owner from public.teams where id = new.team_id;
    perform public.queue_push(
        team_owner,
        'Waiver claim missed',
        public.player_display_name(new.add_player_id) || ': '
        || coalesce(new.failure_reason, 'claim was not successful.'),
        'tarsafantasy://league/' || new.league_id
    );
    return new;
end$$;

drop trigger if exists waiver_claims_notify_lost on public.waiver_claims;
create trigger waiver_claims_notify_lost
    after update on public.waiver_claims
    for each row execute function public.notify_waiver_lost();

-- ---- Drafts ---------------------------------------------------------------

create or replace function public.notify_draft() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    on_clock_team uuid;
    on_clock_owner uuid;
    link text;
begin
    if public.league_is_test(new.league_id) then return new; end if;
    link := 'tarsafantasy://league/' || new.league_id;

    -- Draft went live: tell every claimed team.
    if new.status = 'live' and old.status is distinct from 'live' then
        perform public.queue_push(t.owner_id, 'Draft is live',
                                  'Your league''s draft has started — get in there.', link)
          from public.teams t
         where t.league_id = new.league_id and t.owner_id is not null;
    end if;

    -- New pick on the clock (covers manual picks and auto-pick advances).
    if new.status = 'live'
       and new.current_pick is distinct from old.current_pick
       and new.current_pick between 1 and new.total_picks then
        on_clock_team := public.team_on_clock(new.id, new.current_pick);
        if on_clock_team is not null then
            select owner_id into on_clock_owner from public.teams where id = on_clock_team;
            perform public.queue_push(on_clock_owner, 'You''re on the clock',
                'Pick ' || new.current_pick || ' is yours — '
                || new.pick_seconds || 's to choose.', link);
        end if;
    end if;

    -- Draft finished: tell everyone.
    if new.status = 'complete' and old.status is distinct from 'complete' then
        perform public.queue_push(t.owner_id, 'Draft complete',
                                  'Your league''s draft is done. Set your lineup!', link)
          from public.teams t
         where t.league_id = new.league_id and t.owner_id is not null;
    end if;
    return new;
end$$;

drop trigger if exists drafts_notify on public.drafts;
create trigger drafts_notify
    after update on public.drafts
    for each row execute function public.notify_draft();
