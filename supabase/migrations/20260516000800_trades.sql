-- Trading: propose / accept / reject / counter / cancel, with optional
-- commissioner approval OR league-wide veto voting per league. Accepted
-- trades that include locked players (game already kicked off) are held in
-- pending_execution until the players unlock, then executed by the
-- process_trades cron.

-- 1. Per-league trade settings.
alter table public.leagues
    add column if not exists trade_approval    text not null default 'none',  -- 'none' | 'commissioner' | 'league_vote'
    add column if not exists trade_deadline    timestamptz,                   -- null = no deadline
    add column if not exists trade_vote_hours  int  not null default 24;       -- voting window when trade_approval = 'league_vote'

-- 2. Trades. Status state machine documented inline.
create table if not exists public.trades (
    id                    uuid primary key default gen_random_uuid(),
    league_id             uuid not null references public.leagues(id) on delete cascade,
    proposer_team_id      uuid not null references public.teams(id) on delete cascade,
    recipient_team_id     uuid not null references public.teams(id) on delete cascade,
    proposer_player_ids   text[] not null default '{}',
    recipient_player_ids  text[] not null default '{}',
    note                  text,
    parent_trade_id       uuid references public.trades(id) on delete set null,
    status                text not null default 'pending',
    -- Status transitions:
    --   pending           — awaiting recipient action (accept/reject/counter)
    --   accepted          — recipient accepted; immediately becomes one of the next
    --                       statuses based on league.trade_approval
    --   pending_approval  — awaiting commissioner approve/reject
    --   voting            — open for league-wide veto vote until voting_ends_at
    --   pending_execution — all approvals cleared; holding for locked players
    --   executed          — rosters swapped, transactions logged
    --   rejected          — recipient said no
    --   cancelled         — proposer cancelled before recipient acted
    --   countered         — recipient sent a counter; this trade is closed and
    --                       parent_trade_id on the new row points back here
    --   vetoed            — failed league vote or commish rejection
    voting_ends_at        timestamptz,
    accepted_at           timestamptz,
    executed_at           timestamptz,
    resolved_at           timestamptz,
    failure_reason        text,
    created_at            timestamptz not null default now()
);
create index if not exists trades_league_status_idx     on public.trades (league_id, status);
create index if not exists trades_proposer_idx          on public.trades (proposer_team_id);
create index if not exists trades_recipient_idx         on public.trades (recipient_team_id);
create index if not exists trades_voting_ends_idx       on public.trades (voting_ends_at) where status = 'voting';
create index if not exists trades_pending_exec_idx      on public.trades (status) where status = 'pending_execution';

-- 3. League-vote ballots. One row per (trade, team) voting on the trade.
create table if not exists public.trade_votes (
    trade_id   uuid not null references public.trades(id) on delete cascade,
    team_id    uuid not null references public.teams(id) on delete cascade,
    vote       text not null,   -- 'approve' | 'veto'
    voted_at   timestamptz not null default now(),
    primary key (trade_id, team_id)
);
create index if not exists trade_votes_trade_idx on public.trade_votes (trade_id);

-- 4. RLS.
alter table public.trades      enable row level security;
alter table public.trade_votes enable row level security;

drop policy if exists "trades_read"      on public.trades;
drop policy if exists "trade_votes_read" on public.trade_votes;
drop policy if exists "trade_votes_self" on public.trade_votes;

-- Reads: any signed-in user can read trades + votes for any league they
-- belong to. (We keep the policy simple here; further scoping isn't worth
-- the complexity for our use case.)
create policy "trades_read"      on public.trades      for select using (auth.role() = 'authenticated');
create policy "trade_votes_read" on public.trade_votes for select using (auth.role() = 'authenticated');

-- Writes: client doesn't insert/update trades directly — everything goes
-- through the RPCs below which validate state + authorization. Votes are
-- inserted via vote_trade RPC.

-- 5. RPCs.

-- Validates: proposer is the caller's team, both teams in same league,
-- player IDs are on the right rosters, trade deadline hasn't passed.
create or replace function public.propose_trade(
    p_league_id            uuid,
    p_proposer_team_id     uuid,
    p_recipient_team_id    uuid,
    p_proposer_player_ids  text[],
    p_recipient_player_ids text[],
    p_note                 text default null,
    p_parent_trade_id      uuid default null
) returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    lg            public.leagues;
    proposer_team public.teams;
    recipient_team public.teams;
    is_proposer_owner boolean;
    new_trade     public.trades;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found then raise exception 'league not found'; end if;
    if lg.trade_deadline is not null and lg.trade_deadline < now() then
        raise exception 'trade deadline has passed';
    end if;

    select * into proposer_team from public.teams
        where id = p_proposer_team_id and league_id = p_league_id;
    if not found then raise exception 'proposer team not in league'; end if;
    select * into recipient_team from public.teams
        where id = p_recipient_team_id and league_id = p_league_id;
    if not found then raise exception 'recipient team not in league'; end if;

    is_proposer_owner := proposer_team.owner_id = auth.uid();
    if not is_proposer_owner then
        raise exception 'you can only propose trades from your own team';
    end if;
    if recipient_team.owner_id is null then
        raise exception 'cannot trade with an unowned team';
    end if;
    if p_proposer_team_id = p_recipient_team_id then
        raise exception 'cannot trade with yourself';
    end if;
    if coalesce(array_length(p_proposer_player_ids, 1), 0) = 0
       and coalesce(array_length(p_recipient_player_ids, 1), 0) = 0 then
        raise exception 'a trade needs at least one player on one side';
    end if;
    -- Validate roster membership.
    if not (proposer_team.roster @> p_proposer_player_ids) then
        raise exception 'one or more offered players are not on your roster';
    end if;
    if not (recipient_team.roster @> p_recipient_player_ids) then
        raise exception 'one or more requested players are not on the recipient roster';
    end if;

    insert into public.trades (
        league_id, proposer_team_id, recipient_team_id,
        proposer_player_ids, recipient_player_ids, note, parent_trade_id, status
    ) values (
        p_league_id, p_proposer_team_id, p_recipient_team_id,
        p_proposer_player_ids, p_recipient_player_ids, p_note, p_parent_trade_id, 'pending'
    ) returning * into new_trade;

    -- If this proposal is a counter, mark the parent as 'countered' so it
    -- drops out of the recipient's pending queue.
    if p_parent_trade_id is not null then
        update public.trades
           set status = 'countered', resolved_at = now()
         where id = p_parent_trade_id
           and status = 'pending';
    end if;
    return new_trade;
end$$;

-- Recipient acceptance — flips the trade into the appropriate next state
-- based on the league's trade_approval mode.
create or replace function public.accept_trade(p_trade_id uuid)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t  public.trades;
    lg public.leagues;
    recipient_team public.teams;
    next_status text;
    voting_ends timestamptz;
begin
    select * into t  from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending' then raise exception 'trade is no longer pending'; end if;
    select * into lg from public.leagues where id = t.league_id;
    select * into recipient_team from public.teams where id = t.recipient_team_id;
    if recipient_team.owner_id <> auth.uid() then
        raise exception 'only the recipient owner can accept this trade';
    end if;

    case lg.trade_approval
    when 'none'         then next_status := 'pending_execution';
    when 'commissioner' then next_status := 'pending_approval';
    when 'league_vote'  then
        next_status := 'voting';
        voting_ends := now() + (lg.trade_vote_hours || ' hours')::interval;
    else                     next_status := 'pending_execution';
    end case;

    update public.trades
       set status = next_status,
           accepted_at = now(),
           voting_ends_at = voting_ends
     where id = p_trade_id
     returning * into t;

    -- If approvals are all bypassed, attempt to execute immediately. This is
    -- best-effort — if players are locked, status stays pending_execution
    -- and the cron picks it up later.
    if next_status = 'pending_execution' then
        perform public.attempt_execute_trade(p_trade_id);
        select * into t from public.trades where id = p_trade_id;
    end if;
    return t;
end$$;

-- Recipient rejection.
create or replace function public.reject_trade(p_trade_id uuid)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t public.trades;
    recipient_team public.teams;
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending' then raise exception 'trade is no longer pending'; end if;
    select * into recipient_team from public.teams where id = t.recipient_team_id;
    if recipient_team.owner_id <> auth.uid() then
        raise exception 'only the recipient owner can reject this trade';
    end if;
    update public.trades set status = 'rejected', resolved_at = now()
     where id = p_trade_id returning * into t;
    return t;
end$$;

-- Proposer cancellation (only while still pending).
create or replace function public.cancel_trade(p_trade_id uuid)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t public.trades;
    proposer_team public.teams;
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending' then raise exception 'trade can only be cancelled while pending'; end if;
    select * into proposer_team from public.teams where id = t.proposer_team_id;
    if proposer_team.owner_id <> auth.uid() then
        raise exception 'only the proposer can cancel this trade';
    end if;
    update public.trades set status = 'cancelled', resolved_at = now()
     where id = p_trade_id returning * into t;
    return t;
end$$;

-- Commissioner approval / rejection for trades in pending_approval.
create or replace function public.commish_resolve_trade(
    p_trade_id uuid, p_approve boolean, p_note text default null
) returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t  public.trades;
    lg public.leagues;
begin
    select * into t  from public.trades  where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending_approval' then
        raise exception 'trade is not awaiting commissioner approval';
    end if;
    select * into lg from public.leagues where id = t.league_id;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the commissioner can resolve this trade';
    end if;
    if p_approve then
        update public.trades set status = 'pending_execution', resolved_at = now()
         where id = p_trade_id returning * into t;
        perform public.attempt_execute_trade(p_trade_id);
        select * into t from public.trades where id = p_trade_id;
    else
        update public.trades set status = 'vetoed', resolved_at = now(),
            failure_reason = coalesce(p_note, 'Rejected by commissioner.')
         where id = p_trade_id returning * into t;
    end if;
    return t;
end$$;

-- League-vote ballot. Any team owner in the league other than the proposer
-- or recipient can vote. Re-voting overwrites the prior vote.
create or replace function public.vote_trade(p_trade_id uuid, p_vote text)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t public.trades;
    voter_team public.teams;
begin
    if p_vote not in ('approve', 'veto') then raise exception 'invalid vote'; end if;
    select * into t from public.trades where id = p_trade_id;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'voting' then raise exception 'trade is not in the voting window'; end if;

    select * into voter_team from public.teams
        where league_id = t.league_id and owner_id = auth.uid()
        limit 1;
    if not found then raise exception 'you are not in this league'; end if;
    if voter_team.id in (t.proposer_team_id, t.recipient_team_id) then
        raise exception 'parties to the trade cannot vote';
    end if;

    insert into public.trade_votes (trade_id, team_id, vote)
        values (p_trade_id, voter_team.id, p_vote)
    on conflict (trade_id, team_id) do update
        set vote = excluded.vote, voted_at = now();

    -- Early-finalize if a veto majority is already reached.
    perform public.tally_trade_vote(p_trade_id);
    select * into t from public.trades where id = p_trade_id;
    return t;
end$$;

-- Recounts a trade's votes; if a majority of OTHER OWNERS have voted veto,
-- finalize the trade as vetoed. Called by vote_trade after each ballot, and
-- by process_trades when the window closes.
create or replace function public.tally_trade_vote(p_trade_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    t public.trades;
    other_owner_count int;
    veto_count int;
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found or t.status <> 'voting' then return; end if;

    -- "Other owners" = owned teams in the league minus proposer & recipient.
    select count(*) into other_owner_count
        from public.teams
       where league_id = t.league_id
         and owner_id is not null
         and id not in (t.proposer_team_id, t.recipient_team_id);
    select count(*) into veto_count
        from public.trade_votes
       where trade_id = p_trade_id and vote = 'veto';

    if other_owner_count > 0 and veto_count > (other_owner_count / 2) then
        update public.trades
           set status = 'vetoed',
               resolved_at = now(),
               failure_reason = 'Vetoed by league vote.'
         where id = p_trade_id;
    end if;
end$$;

-- Tries to execute a trade currently in pending_execution. If any included
-- player is "locked" (has a stat row for the most recent week in that
-- league's season), defers and returns without executing.
create or replace function public.attempt_execute_trade(p_trade_id uuid)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t public.trades;
    lg public.leagues;
    proposer public.teams;
    recipient public.teams;
    current_week int;
    locked_count int;
    new_proposer_roster text[];
    new_recipient_roster text[];
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then return null; end if;
    if t.status <> 'pending_execution' then return t; end if;

    select * into lg        from public.leagues where id = t.league_id;
    select * into proposer  from public.teams   where id = t.proposer_team_id;
    select * into recipient from public.teams   where id = t.recipient_team_id;

    -- "Current week" = max week with any stats for this season. Players
    -- listed in the trade with a stat row for that week are considered
    -- locked (game in progress / final).
    select coalesce(max(week), 0) into current_week
        from public.player_games where season = lg.season;

    select count(*) into locked_count
        from public.player_games
       where season = lg.season and week = current_week
         and player_id = any (t.proposer_player_ids || t.recipient_player_ids);

    if locked_count > 0 then
        -- Stay in pending_execution; cron will retry after next week's data
        -- arrives and locked players become "past" rather than "current".
        return t;
    end if;

    -- Build the swapped rosters.
    new_proposer_roster := (
        select array_agg(p) from (
            select unnest(proposer.roster) as p
            except select unnest(t.proposer_player_ids)
        ) s
    );
    new_proposer_roster := coalesce(new_proposer_roster, '{}'::text[]) || t.recipient_player_ids;

    new_recipient_roster := (
        select array_agg(p) from (
            select unnest(recipient.roster) as p
            except select unnest(t.recipient_player_ids)
        ) s
    );
    new_recipient_roster := coalesce(new_recipient_roster, '{}'::text[]) || t.proposer_player_ids;

    update public.teams set roster = new_proposer_roster  where id = proposer.id;
    update public.teams set roster = new_recipient_roster where id = recipient.id;

    update public.trades
       set status = 'executed', executed_at = now(),
           resolved_at = coalesce(resolved_at, now())
     where id = p_trade_id
     returning * into t;

    -- Log a transaction row per side so the Activity feed reflects both
    -- ends of the swap with the player IDs that moved.
    insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
        select t.league_id, proposer.id, 'trade', null, unnest(t.proposer_player_ids), 'completed', null
        from (select 1) x;
    insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
        select t.league_id, proposer.id, 'trade', unnest(t.recipient_player_ids), null, 'completed', null
        from (select 1) x;
    insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
        select t.league_id, recipient.id, 'trade', null, unnest(t.recipient_player_ids), 'completed', null
        from (select 1) x;
    insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
        select t.league_id, recipient.id, 'trade', unnest(t.proposer_player_ids), null, 'completed', null
        from (select 1) x;

    return t;
end$$;

-- 6. Realtime: push trades + trade_votes.
do $$
declare
    t text;
begin
    foreach t in array array['trades', 'trade_votes'] loop
        if exists (
            select 1 from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
        ) then
            execute format('alter publication supabase_realtime drop table public.%I', t);
        end if;
        execute format('alter publication supabase_realtime add table public.%I', t);
    end loop;
end$$;
