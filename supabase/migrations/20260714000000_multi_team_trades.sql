-- Multi-team trades (3+ parties). The 2-party engine is untouched: legacy
-- trades keep their columns and RPC paths byte-for-byte. A multi trade is a
-- trades row with is_multi = true plus one trade_participants row per team,
-- each listing what that team GIVES and RECEIVES (players + pick assets).
-- Conservation is validated at proposal: every given asset is received by
-- exactly one other team.
--
-- Lifecycle mirrors 2-party: pending until EVERY non-proposer participant
-- accepts (the proposer's row is born accepted), then the league's
-- trade_approval mode routes to pending_execution / pending_approval /
-- voting exactly as before — commish_resolve_trade, process_trades, and the
-- voting window need no changes because they are status-driven. vote_trade /
-- tally_trade_vote learn to exclude all participants instead of just the
-- proposer/recipient pair. attempt_execute_trade gains an N-party branch.
--
-- recipient_team_id on a multi trade is set to the first non-proposer
-- participant so legacy readers keep rendering something sensible; the
-- participants table is the source of truth.

alter table public.trades add column if not exists is_multi boolean not null default false;
-- Bumped on each acceptance so Realtime fires and clients can show "2/3
-- accepted" without a second fetch.
alter table public.trades add column if not exists accepted_count int not null default 0;

create table if not exists public.trade_participants (
    id                  uuid primary key default gen_random_uuid(),
    trade_id            uuid not null references public.trades(id)  on delete cascade,
    league_id           uuid not null references public.leagues(id) on delete cascade,
    team_id             uuid not null references public.teams(id)   on delete cascade,
    gives_player_ids    text[] not null default '{}',
    gives_pick_ids      uuid[] not null default '{}',
    receives_player_ids text[] not null default '{}',
    receives_pick_ids   uuid[] not null default '{}',
    accepted_at         timestamptz,
    unique (trade_id, team_id)
);
create index if not exists trade_participants_trade_idx  on public.trade_participants (trade_id);
create index if not exists trade_participants_league_idx on public.trade_participants (league_id);

alter table public.trade_participants enable row level security;
drop policy if exists "trade_participants_read" on public.trade_participants;
create policy "trade_participants_read"
    on public.trade_participants for select
    using (public.is_league_member(league_id));
-- Writes go exclusively through the security-definer RPCs below.

do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public'
          and tablename = 'trade_participants'
    ) then
        execute 'alter publication supabase_realtime drop table public.trade_participants';
    end if;
    execute 'alter publication supabase_realtime add table public.trade_participants';
end$$;

-- 1. propose_multi_trade. p_participants is a jsonb array of
--    {team_id, gives_player_ids, gives_pick_ids,
--     receives_player_ids, receives_pick_ids};
-- the proposer must be one of them. Validates membership, ownership,
-- rosters, pick ownership, and conservation (multiset of gives ==
-- multiset of receives, no asset twice, no team receiving its own give).
create or replace function public.propose_multi_trade(
    p_league_id        uuid,
    p_proposer_team_id uuid,
    p_participants     jsonb,
    p_note             text default null
) returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    lg            public.leagues;
    tm            public.teams;
    t             public.trades;
    part          jsonb;
    n_parts       int;
    all_team_ids  uuid[] := '{}';
    give_players  text[] := '{}';
    recv_players  text[] := '{}';
    give_picks    uuid[] := '{}';
    recv_picks    uuid[] := '{}';
    first_other   uuid;
    team_id       uuid;
    gives_p       text[];
    recvs_p       text[];
    gives_k       uuid[];
    recvs_k       uuid[];
    x             text;
    k             uuid;
    proposer_name text;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found then raise exception 'league not found'; end if;
    if lg.trade_deadline is not null and now() > lg.trade_deadline then
        raise exception 'trade deadline has passed';
    end if;

    select * into tm from public.teams
        where id = p_proposer_team_id and league_id = p_league_id;
    if not found then raise exception 'proposer team not in league'; end if;
    if tm.owner_id is distinct from auth.uid() then
        raise exception 'you can only propose trades from your own team';
    end if;
    proposer_name := tm.name;

    if jsonb_typeof(p_participants) is distinct from 'array' then
        raise exception 'participants payload must be an array';
    end if;
    n_parts := jsonb_array_length(p_participants);
    if n_parts < 3 then
        raise exception 'a multi-team trade needs at least 3 teams';
    end if;
    if n_parts > 8 then
        raise exception 'too many teams in one trade (max 8)';
    end if;

    for part in select * from jsonb_array_elements(p_participants) loop
        team_id := (part->>'team_id')::uuid;
        if team_id = any(all_team_ids) then
            raise exception 'duplicate team in trade';
        end if;
        all_team_ids := all_team_ids || team_id;

        select * into tm from public.teams
            where id = team_id and league_id = p_league_id;
        if not found then raise exception 'team % not in league', team_id; end if;
        if tm.owner_id is null then
            raise exception 'cannot trade with an unowned team';
        end if;

        gives_p := coalesce((select array_agg(v) from jsonb_array_elements_text(part->'gives_player_ids') v), '{}');
        recvs_p := coalesce((select array_agg(v) from jsonb_array_elements_text(part->'receives_player_ids') v), '{}');
        gives_k := coalesce((select array_agg(v::uuid) from jsonb_array_elements_text(part->'gives_pick_ids') v), '{}');
        recvs_k := coalesce((select array_agg(v::uuid) from jsonb_array_elements_text(part->'receives_pick_ids') v), '{}');

        if not (tm.roster @> gives_p) then
            raise exception '% does not roster all offered players', tm.name;
        end if;
        perform public.validate_trade_picks(p_league_id, team_id, gives_k);

        -- A team can't receive what it gives.
        if gives_p && recvs_p or gives_k && recvs_k then
            raise exception '% cannot receive an asset it is giving', tm.name;
        end if;

        -- Accumulate, rejecting any asset that appears twice on a side.
        foreach x in array gives_p loop
            if x = any(give_players) then raise exception 'player % is given twice', x; end if;
            give_players := give_players || x;
        end loop;
        foreach x in array recvs_p loop
            if x = any(recv_players) then raise exception 'player % is received twice', x; end if;
            recv_players := recv_players || x;
        end loop;
        foreach k in array gives_k loop
            if k = any(give_picks) then raise exception 'a pick is given twice'; end if;
            give_picks := give_picks || k;
        end loop;
        foreach k in array recvs_k loop
            if k = any(recv_picks) then raise exception 'a pick is received twice'; end if;
            recv_picks := recv_picks || k;
        end loop;

        if first_other is null and team_id <> p_proposer_team_id then
            first_other := team_id;
        end if;
    end loop;

    if not (p_proposer_team_id = any(all_team_ids)) then
        raise exception 'the proposer must be a participant';
    end if;

    -- Conservation: everything given is received exactly once, and nothing
    -- is received out of thin air.
    if (select array_agg(v order by v) from unnest(give_players) v)
       is distinct from
       (select array_agg(v order by v) from unnest(recv_players) v) then
        raise exception 'every traded player must be given by one team and received by another';
    end if;
    if (select array_agg(v order by v) from unnest(give_picks) v)
       is distinct from
       (select array_agg(v order by v) from unnest(recv_picks) v) then
        raise exception 'every traded pick must be given by one team and received by another';
    end if;
    if coalesce(array_length(give_players, 1), 0)
       + coalesce(array_length(give_picks, 1), 0) = 0 then
        raise exception 'trade must include at least one player or pick';
    end if;

    insert into public.trades (
        league_id, proposer_team_id, recipient_team_id,
        note, status, is_multi, accepted_count
    ) values (
        p_league_id, p_proposer_team_id, first_other,
        nullif(p_note, ''), 'pending', true, 1
    ) returning * into t;

    insert into public.trade_participants (
        trade_id, league_id, team_id,
        gives_player_ids, gives_pick_ids,
        receives_player_ids, receives_pick_ids,
        accepted_at
    )
    select
        t.id, p_league_id, (p->>'team_id')::uuid,
        coalesce((select array_agg(v) from jsonb_array_elements_text(p->'gives_player_ids') v), '{}'),
        coalesce((select array_agg(v::uuid) from jsonb_array_elements_text(p->'gives_pick_ids') v), '{}'),
        coalesce((select array_agg(v) from jsonb_array_elements_text(p->'receives_player_ids') v), '{}'),
        coalesce((select array_agg(v::uuid) from jsonb_array_elements_text(p->'receives_pick_ids') v), '{}'),
        case when (p->>'team_id')::uuid = p_proposer_team_id then now() end
    from jsonb_array_elements(p_participants) p;

    -- Notify the other participants. notify_trade_created skips multi rows
    -- (participants don't exist yet when the AFTER INSERT trigger fires).
    if not public.league_is_test(p_league_id) then
        perform public.queue_push(
            tm2.owner_id, 'New trade offer',
            proposer_name || ' proposed a ' || n_parts || '-team trade.',
            'tarsafantasy://league/' || p_league_id
        )
        from public.teams tm2
        where tm2.id = any(all_team_ids)
          and tm2.id <> p_proposer_team_id
          and tm2.owner_id is not null;
    end if;

    return t;
end$$;

revoke execute on function public.propose_multi_trade(uuid, uuid, jsonb, text) from public, anon;
grant  execute on function public.propose_multi_trade(uuid, uuid, jsonb, text) to authenticated;

-- 2. accept_trade: legacy path unchanged; multi path records the caller's
-- participant acceptance and only advances the status when everyone is in.
create or replace function public.accept_trade(p_trade_id uuid)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t  public.trades;
    lg public.leagues;
    recipient_team public.teams;
    part public.trade_participants;
    next_status text;
    voting_ends timestamptz;
    total_parts int;
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending' then raise exception 'trade is no longer pending'; end if;
    select * into lg from public.leagues where id = t.league_id;

    if t.is_multi then
        select p.* into part
          from public.trade_participants p
          join public.teams tm on tm.id = p.team_id
         where p.trade_id = t.id
           and p.accepted_at is null
           and tm.owner_id = auth.uid()
         for update of p;
        if not found then
            raise exception 'no pending acceptance for your team on this trade';
        end if;
        update public.trade_participants set accepted_at = now() where id = part.id;
        update public.trades set accepted_count = accepted_count + 1
         where id = t.id returning * into t;

        if exists (select 1 from public.trade_participants
                    where trade_id = t.id and accepted_at is null) then
            -- Still waiting on someone; tell the proposer about the progress.
            if not public.league_is_test(t.league_id) then
                select count(*) into total_parts
                  from public.trade_participants where trade_id = t.id;
                perform public.queue_push(
                    pt.owner_id, 'Trade accepted',
                    at.name || ' accepted your multi-team trade ('
                        || t.accepted_count || '/' || total_parts || ').',
                    'tarsafantasy://league/' || t.league_id
                )
                from public.teams pt, public.teams at
                where pt.id = t.proposer_team_id and pt.owner_id is not null
                  and at.id = part.team_id;
            end if;
            return t;
        end if;
    else
        select * into recipient_team from public.teams where id = t.recipient_team_id;
        if recipient_team.owner_id <> auth.uid() then
            raise exception 'only the recipient owner can accept this trade';
        end if;
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

    if next_status = 'pending_execution' then
        perform public.attempt_execute_trade(p_trade_id);
        select * into t from public.trades where id = p_trade_id;
    end if;
    return t;
end$$;

-- 3. reject_trade: any non-proposer participant can kill a multi trade.
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

    if t.is_multi then
        if not exists (
            select 1 from public.trade_participants p
              join public.teams tm on tm.id = p.team_id
             where p.trade_id = t.id
               and p.team_id <> t.proposer_team_id
               and tm.owner_id = auth.uid()
        ) then
            raise exception 'only a participant can reject this trade';
        end if;
    else
        select * into recipient_team from public.teams where id = t.recipient_team_id;
        if recipient_team.owner_id <> auth.uid() then
            raise exception 'only the recipient owner can reject this trade';
        end if;
    end if;

    update public.trades set status = 'rejected', resolved_at = now()
     where id = p_trade_id returning * into t;
    return t;
end$$;

-- 4. vote_trade / tally_trade_vote: exclude every participant of a multi
-- trade (not just proposer/recipient) from voting and from the veto quorum.
create or replace function public.trade_party_team_ids(p_trade public.trades)
returns uuid[] language sql stable as $$
    select case when p_trade.is_multi
        then coalesce((select array_agg(team_id) from public.trade_participants
                        where trade_id = p_trade.id), '{}')
        else array[p_trade.proposer_team_id, p_trade.recipient_team_id]
    end
$$;

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
    if voter_team.id = any(public.trade_party_team_ids(t)) then
        raise exception 'parties to the trade cannot vote';
    end if;

    insert into public.trade_votes (trade_id, team_id, vote)
        values (p_trade_id, voter_team.id, p_vote)
    on conflict (trade_id, team_id) do update
        set vote = excluded.vote, voted_at = now();

    perform public.tally_trade_vote(p_trade_id);
    select * into t from public.trades where id = p_trade_id;
    return t;
end$$;

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

    select count(*) into other_owner_count
        from public.teams
       where league_id = t.league_id
         and owner_id is not null
         and not (id = any(public.trade_party_team_ids(t)));
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

-- 5. attempt_execute_trade: legacy 2-party branch is verbatim from
-- 20260713000000 (incl. the pick-row locks); the multi branch generalizes
-- the same steps to N participants.
create or replace function public.attempt_execute_trade(p_trade_id uuid)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t         public.trades;
    proposer  public.teams;
    recipient public.teams;
    part      public.trade_participants;
    tm        public.teams;
    locked_player text;
    new_roster           text[];
    new_proposer_roster  text[];
    new_recipient_roster text[];
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending_execution' then return t; end if;

    if t.is_multi then
        -- Lock every participant team (deterministic order) and every given
        -- pick before re-validating — same discipline as the 2-party path.
        perform 1 from public.teams
         where id in (select team_id from public.trade_participants where trade_id = t.id)
         order by id
         for update;
        perform 1 from public.draft_pick_assets
         where id in (select unnest(gives_pick_ids)
                        from public.trade_participants where trade_id = t.id)
         for update;

        if exists (
            select 1 from public.trade_participants p
              join public.teams tm2 on tm2.id = p.team_id
             where p.trade_id = t.id
               and not (tm2.roster @> p.gives_player_ids)
        ) then
            update public.trades
               set status = 'cancelled', resolved_at = now(),
                   failure_reason = 'a team no longer rosters all traded players'
             where id = t.id returning * into t;
            return t;
        end if;
        if exists (
            select 1 from public.trade_participants p
             cross join unnest(p.gives_pick_ids) g
              join public.draft_pick_assets a on a.id = g
             where p.trade_id = t.id
               and a.owner_team_id <> p.team_id
        ) then
            update public.trades
               set status = 'cancelled', resolved_at = now(),
                   failure_reason = 'a traded pick changed hands before execution'
             where id = t.id returning * into t;
            return t;
        end if;

        -- Defer while any traded player's game is underway.
        select pc.name into locked_player
          from (select unnest(gives_player_ids) as pid
                  from public.trade_participants where trade_id = t.id) s
          join public.players_cache pc on pc.id = s.pid
          join public.nfl_schedules g
            on (g.home_team = pc.team or g.away_team = pc.team)
           and g.status <> 'final'
           and g.kickoff is not null
           and g.kickoff <= now()
           and now() < g.kickoff + interval '5 hours'
         limit 1;
        if locked_player is not null then
            return t;   -- stay pending_execution; the hourly cron retries
        end if;

        perform public.mark_roster_write();
        for part in select * from public.trade_participants where trade_id = t.id loop
            select * into tm from public.teams where id = part.team_id;
            new_roster := (
                select array_agg(p) from (
                    select unnest(tm.roster) as p
                    except select unnest(part.gives_player_ids)
                ) s
            );
            new_roster := coalesce(new_roster, '{}'::text[]) || part.receives_player_ids;
            update public.teams set roster = new_roster where id = part.team_id;

            update public.draft_pick_assets
               set owner_team_id = part.team_id
             where id = any(part.receives_pick_ids);

            insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
                select t.league_id, part.team_id, 'trade', null, unnest(part.gives_player_ids), 'completed', null;
            insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
                select t.league_id, part.team_id, 'trade', unnest(part.receives_player_ids), null, 'completed', null;
        end loop;

        update public.trades
           set status = 'executed', executed_at = now(),
               resolved_at = coalesce(resolved_at, now())
         where id = t.id
         returning * into t;
        return t;
    end if;

    select * into proposer  from public.teams where id = t.proposer_team_id  for update;
    select * into recipient from public.teams where id = t.recipient_team_id for update;

    -- Both sides must still roster what they're sending.
    if coalesce(array_length(t.proposer_player_ids, 1), 0) > 0
       and not (proposer.roster @> t.proposer_player_ids) then
        update public.trades
           set status = 'cancelled', resolved_at = now(),
               failure_reason = 'proposer no longer rosters all traded players'
         where id = t.id returning * into t;
        return t;
    end if;
    if coalesce(array_length(t.recipient_player_ids, 1), 0) > 0
       and not (recipient.roster @> t.recipient_player_ids) then
        update public.trades
           set status = 'cancelled', resolved_at = now(),
               failure_reason = 'recipient no longer rosters all traded players'
         where id = t.id returning * into t;
        return t;
    end if;

    -- ...and still own the picks they're sending. Lock the asset rows first
    -- (mirroring the team locks above): two pending trades offering the same
    -- pick could otherwise both pass this check under concurrent execution
    -- and both mark themselves executed.
    perform 1 from public.draft_pick_assets a
     where a.id = any(t.proposer_pick_ids || t.recipient_pick_ids)
     for update;
    if exists (select 1 from public.draft_pick_assets a
                where a.id = any(t.proposer_pick_ids)
                  and a.owner_team_id <> t.proposer_team_id)
       or exists (select 1 from public.draft_pick_assets a
                where a.id = any(t.recipient_pick_ids)
                  and a.owner_team_id <> t.recipient_team_id) then
        update public.trades
           set status = 'cancelled', resolved_at = now(),
               failure_reason = 'a traded pick changed hands before execution'
         where id = t.id returning * into t;
        return t;
    end if;

    -- Defer while any traded player's game is underway: locked iff the NFL
    -- team has a not-final game with kickoff <= now() < kickoff + 5h.
    select pc.name into locked_player
      from unnest(t.proposer_player_ids || t.recipient_player_ids) pid
      join public.players_cache pc on pc.id = pid
      join public.nfl_schedules g
        on (g.home_team = pc.team or g.away_team = pc.team)
       and g.status <> 'final'
       and g.kickoff is not null
       and g.kickoff <= now()
       and now() < g.kickoff + interval '5 hours'
     limit 1;
    if locked_player is not null then
        return t;   -- stay pending_execution; the hourly cron retries
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

    perform public.mark_roster_write();
    update public.teams set roster = new_proposer_roster  where id = proposer.id;
    update public.teams set roster = new_recipient_roster where id = recipient.id;

    -- Swap pick ownership.
    update public.draft_pick_assets
       set owner_team_id = t.recipient_team_id
     where id = any(t.proposer_pick_ids);
    update public.draft_pick_assets
       set owner_team_id = t.proposer_team_id
     where id = any(t.recipient_pick_ids);

    update public.trades
       set status = 'executed', executed_at = now(), resolved_at = now()
     where id = t.id
     returning * into t;

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

-- 6. Push triggers: multi trades notify all participants. The created
-- trigger skips multi rows entirely — participants don't exist yet when the
-- AFTER INSERT fires, so propose_multi_trade queues those pushes itself.
create or replace function public.notify_trade_created() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    recipient_owner uuid;
    proposer_name   text;
begin
    if public.league_is_test(new.league_id) then return new; end if;
    if new.status <> 'pending' then return new; end if;
    if new.is_multi then return new; end if;
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
    link := 'tarsafantasy://league/' || new.league_id;

    if new.is_multi then
        -- Everyone with a stake hears about terminal transitions; the
        -- per-acceptance progress pushes come from accept_trade itself.
        if new.status = 'rejected' and old.status = 'pending' then
            perform public.queue_push(tm.owner_id, 'Trade declined',
                'Your multi-team trade was declined.', link)
              from public.trade_participants p
              join public.teams tm on tm.id = p.team_id
             where p.trade_id = new.id and tm.owner_id is not null;
        elsif new.status in ('pending_execution', 'pending_approval', 'voting')
              and old.status = 'pending' then
            perform public.queue_push(tm.owner_id, 'Trade accepted',
                'All teams accepted the multi-team trade'
                || case when new.status in ('pending_approval', 'voting')
                        then ' — pending league review.' else '.' end, link)
              from public.trade_participants p
              join public.teams tm on tm.id = p.team_id
             where p.trade_id = new.id and tm.owner_id is not null;
        elsif new.status = 'vetoed' then
            perform public.queue_push(tm.owner_id, 'Trade vetoed',
                'Your multi-team trade was vetoed.', link)
              from public.trade_participants p
              join public.teams tm on tm.id = p.team_id
             where p.trade_id = new.id and tm.owner_id is not null;
        elsif new.status = 'executed' then
            perform public.queue_push(tm.owner_id, 'Trade processed',
                'Your multi-team trade is complete.', link)
              from public.trade_participants p
              join public.teams tm on tm.id = p.team_id
             where p.trade_id = new.id and tm.owner_id is not null;
        end if;
        return new;
    end if;

    select owner_id, name into proposer_owner,  proposer_name
      from public.teams where id = new.proposer_team_id;
    select owner_id, name into recipient_owner, recipient_name
      from public.teams where id = new.recipient_team_id;

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
