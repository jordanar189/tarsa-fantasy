-- Auction drafts: serial live auction (one open lot at a time). The drafts
-- row is reused — format = 'auction', current_pick becomes the NOMINATION
-- counter (round-robin over pick_order, skipping teams whose roster is
-- full), pick_deadline becomes the nomination clock. Bidding state lives in
-- auction_lots: one row per nominated player, open until its bid_deadline
-- passes, then settled to the high bidder. Winners are ALSO logged to
-- draft_picks (pick_number = nomination number) so the board, roster
-- append, and post-draft surfaces reuse the snake infrastructure.
--
-- Money rules: budget per team on drafts.auction_budget (default $200),
-- min bid $1, whole dollars. A team's max bid is
--   budget − spent − (open roster slots − 1)
-- so every team can always fill out its roster at $1 each. Keepers pre-fill
-- as $1 sold lots at draft start (round-cost keeper settings are a snake
-- concept and are ignored for auctions).
--
-- Clocks: nomination clock = drafts.pick_seconds; bid window 15s; a bid in
-- the final 10s extends the deadline to now()+10s (anti-snipe). settle_lot
-- is called by any connected client when the local countdown hits zero and
-- by the draft_tick cron as backstop — it is idempotent and deadline-gated.
-- v1 note: pausing an auction freezes only the nomination clock; an open
-- lot still settles on its own deadline.

alter table public.drafts
    add column if not exists auction_budget int not null default 200;

create table if not exists public.auction_lots (
    id                      uuid primary key default gen_random_uuid(),
    draft_id                uuid not null references public.drafts(id) on delete cascade,
    league_id               uuid not null references public.leagues(id) on delete cascade,
    player_id               text not null,
    nomination_number       int  not null,
    nominating_team_id      uuid not null references public.teams(id),
    current_bid             int  not null,
    -- High bidder while open; winner once sold.
    current_bidder_team_id  uuid not null references public.teams(id),
    bid_deadline            timestamptz,
    status                  text not null default 'open',   -- 'open' | 'sold'
    sold_price              int,
    created_at              timestamptz not null default now(),
    settled_at              timestamptz,
    unique (draft_id, player_id)
);
create index if not exists auction_lots_draft_idx on public.auction_lots (draft_id, nomination_number);
-- Serial auction invariant: at most one open lot per draft.
create unique index if not exists auction_lots_one_open
    on public.auction_lots (draft_id) where status = 'open';

alter table public.auction_lots enable row level security;
drop policy if exists "auction_lots_read" on public.auction_lots;
create policy "auction_lots_read"
    on public.auction_lots for select
    using (public.is_league_member(league_id));
-- Writes go exclusively through the RPCs below.

do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public'
          and tablename = 'auction_lots'
    ) then
        execute 'alter publication supabase_realtime drop table public.auction_lots';
    end if;
    execute 'alter publication supabase_realtime add table public.auction_lots';
end$$;

-- ---------------------------------------------------------------------------
-- Helpers. Sold lots (keepers included) are the source of truth for both a
-- team's spend and its filled roster slots.

create or replace function public.auction_slots_per_team(p_draft public.drafts)
returns int language sql stable as $$
    select case when coalesce(array_length(p_draft.pick_order, 1), 0) = 0 then 0
                else p_draft.total_picks / array_length(p_draft.pick_order, 1) end
$$;

create or replace function public.auction_team_spent(p_draft_id uuid, p_team_id uuid)
returns int language sql stable as $$
    select coalesce(sum(sold_price), 0)::int from public.auction_lots
     where draft_id = p_draft_id and status = 'sold'
       and current_bidder_team_id = p_team_id
$$;

create or replace function public.auction_team_won(p_draft_id uuid, p_team_id uuid)
returns int language sql stable as $$
    select count(*)::int from public.auction_lots
     where draft_id = p_draft_id and status = 'sold'
       and current_bidder_team_id = p_team_id
$$;

-- budget − spent − ($1 reserved per other open slot); 0 when the roster is
-- already full.
create or replace function public.auction_max_bid(p_draft_id uuid, p_team_id uuid)
returns int language plpgsql stable as $$
declare
    d public.drafts;
    remaining int;
begin
    select * into d from public.drafts where id = p_draft_id;
    if not found then return 0; end if;
    remaining := public.auction_slots_per_team(d) - public.auction_team_won(p_draft_id, p_team_id);
    if remaining <= 0 then return 0; end if;
    return greatest(0, d.auction_budget
                       - public.auction_team_spent(p_draft_id, p_team_id)
                       - (remaining - 1));
end$$;

-- Full roster size from a league's roster_config jsonb. Mirrors the Swift
-- RosterConfig.totalSize defaults (and draft_tick's totalRounds math) so the
-- server can size an auction independently of the client's total_picks —
-- keeper-lite clients deliberately send a keeper-reduced size that would
-- otherwise double-count keeper pre-fills.
create or replace function public.roster_config_total_size(rc jsonb)
returns int language sql immutable as $$
    select coalesce((rc->>'qb')::int, 1)
         + coalesce((rc->>'rb')::int, 2)
         + coalesce((rc->>'wr')::int, 2)
         + coalesce((rc->>'te')::int, 1)
         + coalesce((rc->>'flex')::int, 1)
         + coalesce((rc->>'superflex')::int, 0)
         + coalesce((rc->>'wrFlex')::int, 0)
         + coalesce((rc->>'recFlex')::int, 0)
         + coalesce((rc->>'k')::int, 1)
         + coalesce((rc->>'def')::int, 1)
         + coalesce((rc->>'bench')::int, 6)
$$;

-- Round-robin team for a nomination counter (1-indexed; no snake reversal).
create or replace function public.auction_nominator_at(p_draft public.drafts, p_counter int)
returns uuid language sql stable as $$
    select (p_draft.pick_order[((p_counter - 1) % array_length(p_draft.pick_order, 1)) + 1])::uuid
$$;

-- Next nomination counter >= p_from whose team still has open slots; null
-- when every team is full. Bounded to one full rotation.
create or replace function public.auction_next_nomination(p_draft_id uuid, p_from int)
returns int language plpgsql stable as $$
declare
    d public.drafts;
    n int;
    slots int;
    i int;
    tid uuid;
begin
    select * into d from public.drafts where id = p_draft_id;
    if not found then return null; end if;
    n := coalesce(array_length(d.pick_order, 1), 0);
    if n = 0 then return null; end if;
    slots := public.auction_slots_per_team(d);
    for i in p_from..(p_from + n - 1) loop
        tid := public.auction_nominator_at(d, i);
        if public.auction_team_won(p_draft_id, tid) < slots then
            return i;
        end if;
    end loop;
    return null;
end$$;

-- ---------------------------------------------------------------------------
-- nominate_player: opens a lot for the team on the nomination clock. The
-- opening amount is the nominator's first bid.
create or replace function public.nominate_player(
    p_draft_id  uuid,
    p_team_id   uuid,
    p_player_id text,
    p_amount    int default 1,
    p_is_auto   boolean default false
) returns public.auction_lots
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    expected uuid;
    is_owner boolean;
    is_commish boolean;
    lot public.auction_lots;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    if d.format <> 'auction' then raise exception 'not an auction draft'; end if;
    if d.status <> 'live' then raise exception 'draft is not live'; end if;
    if exists (select 1 from public.auction_lots
                where draft_id = p_draft_id and status = 'open') then
        raise exception 'a lot is already open';
    end if;

    expected := public.auction_nominator_at(d, d.current_pick);
    if expected is null or expected <> p_team_id then
        raise exception 'team is not on the nomination clock';
    end if;

    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if not p_is_auto
       and coalesce(is_owner, false) is false
       and coalesce(is_commish, false) is false
    then raise exception 'not authorized to nominate for this team'; end if;

    if p_amount < 1 then raise exception 'minimum bid is $1'; end if;
    if p_amount > public.auction_max_bid(p_draft_id, p_team_id) then
        raise exception 'bid exceeds your max bid';
    end if;

    -- Player must be genuinely available: never auctioned in this draft and
    -- on no roster in the league (covers keepers, which stay rostered).
    if exists (select 1 from public.teams t
                where t.league_id = d.league_id and p_player_id = any(t.roster)) then
        raise exception 'player is already rostered';
    end if;

    insert into public.auction_lots (
        draft_id, league_id, player_id, nomination_number,
        nominating_team_id, current_bid, current_bidder_team_id, bid_deadline
    ) values (
        p_draft_id, d.league_id, p_player_id, d.current_pick,
        p_team_id, p_amount, p_team_id, now() + interval '15 seconds'
    ) returning * into lot;

    -- The nomination clock is satisfied; the lot's bid clock takes over.
    update public.drafts set pick_deadline = null where id = p_draft_id;
    return lot;
end$$;

-- ---------------------------------------------------------------------------
-- place_bid: strictly increasing whole-dollar bids on the open lot, capped
-- by the bidder's max bid, with anti-snipe extension.
create or replace function public.place_bid(
    p_draft_id uuid,
    p_team_id  uuid,
    p_amount   int
) returns public.auction_lots
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    lot public.auction_lots;
    is_owner boolean;
    is_commish boolean;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    if d.status <> 'live' then raise exception 'draft is not live'; end if;

    select * into lot from public.auction_lots
     where draft_id = p_draft_id and status = 'open'
     for update;
    if not found then raise exception 'no lot is open'; end if;
    if lot.bid_deadline is not null and now() >= lot.bid_deadline then
        raise exception 'bidding has closed on this lot';
    end if;

    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id and t.league_id = d.league_id;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if is_owner is null then raise exception 'team not in league'; end if;
    if coalesce(is_owner, false) is false
       and coalesce(is_commish, false) is false
    then raise exception 'not authorized to bid for this team'; end if;

    if p_team_id = lot.current_bidder_team_id then
        raise exception 'team is already the high bidder';
    end if;
    if p_amount <= lot.current_bid then
        raise exception 'bid must beat the current high bid';
    end if;
    if p_amount > public.auction_max_bid(p_draft_id, p_team_id) then
        raise exception 'bid exceeds your max bid';
    end if;

    update public.auction_lots
       set current_bid = p_amount,
           current_bidder_team_id = p_team_id,
           -- Anti-snipe: a bid inside the final 10s pushes the close out.
           bid_deadline = greatest(bid_deadline, now() + interval '10 seconds')
     where id = lot.id
     returning * into lot;
    return lot;
end$$;

-- ---------------------------------------------------------------------------
-- settle_lot: idempotent, deadline-gated close of the open lot. Awards the
-- player, logs the draft_picks row, advances the nomination pointer, and
-- completes the draft when every roster is full. Callable by any league
-- member (client clocks) or the service role (draft_tick backstop).
create or replace function public.settle_lot(p_draft_id uuid)
returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    lot public.auction_lots;
    sold_count int;
    next_nom int;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    if d.format <> 'auction' then raise exception 'not an auction draft'; end if;
    if auth.uid() is not null and not public.is_league_member(d.league_id) then
        raise exception 'not a member of this league';
    end if;
    if d.status <> 'live' then return d; end if;

    select * into lot from public.auction_lots
     where draft_id = p_draft_id and status = 'open'
     for update;
    if not found then return d; end if;
    if lot.bid_deadline is not null and now() < lot.bid_deadline then
        return d;   -- not ready; caller re-checks on its next tick
    end if;

    update public.auction_lots
       set status = 'sold',
           sold_price = lot.current_bid,
           settled_at = now()
     where id = lot.id;

    insert into public.draft_picks (draft_id, pick_number, team_id, player_id, auto_pick)
    values (p_draft_id, lot.nomination_number, lot.current_bidder_team_id, lot.player_id, false);

    perform public.mark_roster_write();
    update public.teams
       set roster = array_append(roster, lot.player_id)
     where id = lot.current_bidder_team_id;

    select count(*) into sold_count from public.auction_lots
     where draft_id = p_draft_id and status = 'sold';

    if sold_count >= d.total_picks then
        update public.drafts
           set status = 'complete',
               completed_at = now(),
               current_pick = d.total_picks + 1,
               pick_deadline = null
         where id = p_draft_id
         returning * into d;
        return d;
    end if;

    next_nom := public.auction_next_nomination(p_draft_id, d.current_pick + 1);
    if next_nom is null then
        -- Every team full despite sold_count < total_picks (degenerate
        -- config); close out rather than spin.
        update public.drafts
           set status = 'complete', completed_at = now(),
               current_pick = d.total_picks + 1, pick_deadline = null
         where id = p_draft_id
         returning * into d;
    else
        update public.drafts
           set current_pick = next_nom,
               pick_deadline = now() + (d.pick_seconds || ' seconds')::interval
         where id = p_draft_id
         returning * into d;
    end if;
    return d;
end$$;

revoke execute on function public.nominate_player(uuid, uuid, text, int, boolean) from public, anon;
revoke execute on function public.place_bid(uuid, uuid, int) from public, anon;
revoke execute on function public.settle_lot(uuid) from public, anon;
grant  execute on function public.nominate_player(uuid, uuid, text, int, boolean) to authenticated, service_role;
grant  execute on function public.place_bid(uuid, uuid, int) to authenticated, service_role;
grant  execute on function public.settle_lot(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- start_draft: redefined with an auction branch. Snake/linear path is
-- byte-for-byte the 20260713000100 version. The auction branch shares the
-- keeper roster-trim, pre-fills keepers as $1 sold lots (+ draft_picks rows
-- numbered 1..K), and opens the nomination clock — traded-pick overrides and
-- round-cost placement are snake concepts and don't apply.
create or replace function public.start_draft(p_draft_id uuid)
returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    is_commish boolean;
    kc int;
    lg_season int;
    round_cost boolean;
    team_count int;
    total_rounds int;
    overrides jsonb := '{}'::jsonb;
    a record;
    t record;
    pick_no int;
    pos int;
    r int;
    k text;
    cost int;
    first_pick int;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can start the draft';
    end if;
    if d.status = 'live' then return d; end if;
    if d.status = 'complete' then raise exception 'draft is already complete'; end if;

    select coalesce(l.keeper_count, 0), l.season, coalesce(l.keeper_round_cost, false)
      into kc, lg_season, round_cost
      from public.leagues l where l.id = d.league_id;
    if kc > 0 then
        perform public.mark_roster_write();
        update public.teams t2
           set keepers  = (select coalesce(array_agg(x), '{}'::text[])
                             from unnest(t2.keepers) x where x = any(t2.roster)),
               roster   = (select coalesce(array_agg(x), '{}'::text[])
                             from unnest(t2.roster) x where x = any(t2.keepers)),
               starters = '{}',
               ir       = (select coalesce(array_agg(x), '{}'::text[])
                             from unnest(t2.ir) x where x = any(t2.keepers)),
               taxi     = (select coalesce(array_agg(x), '{}'::text[])
                             from unnest(t2.taxi) x where x = any(t2.keepers))
         where t2.league_id = d.league_id;
    end if;

    team_count := array_length(d.pick_order, 1);

    if d.format = 'auction' then
        -- Server-authoritative sizing: every team fills its FULL roster
        -- (keepers included), so normalize total_picks from roster_config
        -- rather than trusting the client's value — keeper-lite setup sends
        -- a keeper-reduced size that would double-count the $1 pre-fills.
        if team_count is not null and team_count > 0 then
            select public.roster_config_total_size(l.roster_config) * team_count
              into total_rounds
              from public.leagues l where l.id = d.league_id;
            if total_rounds is not null and total_rounds > 0 then
                update public.drafts set total_picks = total_rounds where id = p_draft_id;
                d.total_picks := total_rounds;
            end if;
        end if;

        -- Keepers occupy roster slots and charge $1 against the budget.
        pick_no := 0;
        if kc > 0 then
            for t in
                select tm.id, tm.keepers from public.teams tm
                 where tm.league_id = d.league_id
                   and coalesce(array_length(tm.keepers, 1), 0) > 0
                 order by tm.sort_index
            loop
                foreach k in array t.keepers loop
                    pick_no := pick_no + 1;
                    insert into public.draft_picks (draft_id, pick_number, team_id, player_id, auto_pick)
                    values (d.id, pick_no, t.id, k, false);
                    insert into public.auction_lots (
                        draft_id, league_id, player_id, nomination_number,
                        nominating_team_id, current_bid, current_bidder_team_id,
                        bid_deadline, status, sold_price, settled_at
                    ) values (
                        d.id, d.league_id, k, pick_no,
                        t.id, 1, t.id, now(), 'sold', 1, now()
                    );
                end loop;
            end loop;
        end if;

        first_pick := public.auction_next_nomination(p_draft_id, pick_no + 1);
        if first_pick is null then
            update public.drafts
               set status = 'complete',
                   started_at = coalesce(started_at, now()),
                   completed_at = now(),
                   current_pick = d.total_picks + 1,
                   pick_deadline = null, paused_at = null, paused_remaining = null
             where id = p_draft_id
             returning * into d;
        else
            update public.drafts
               set status = 'live',
                   started_at = coalesce(started_at, now()),
                   current_pick = first_pick,
                   pick_deadline = now() + (d.pick_seconds || ' seconds')::interval,
                   paused_at = null, paused_remaining = null
             where id = p_draft_id
             returning * into d;
        end if;
        return d;
    end if;

    -- Traded picks → {pick_number: owner}. Only rounds inside the draft and
    -- only assets whose owner differs from the original slot matter.
    if team_count is not null and team_count > 0 then
        for a in
            select dpa.round, dpa.original_team_id, dpa.owner_team_id
              from public.draft_pick_assets dpa
             where dpa.league_id = d.league_id
               and dpa.season = lg_season
               and dpa.owner_team_id <> dpa.original_team_id
        loop
            r := a.round;
            if r < 1 or r > (d.total_picks + team_count - 1) / team_count then continue; end if;
            pos := array_position(d.pick_order, a.original_team_id::text);
            if pos is null then continue; end if;
            if d.format = 'snake' and ((r - 1) % 2 = 1) then
                pos := team_count + 1 - pos;
            end if;
            pick_no := (r - 1) * team_count + pos;
            overrides := overrides || jsonb_build_object(pick_no::text, a.owner_team_id::text);
        end loop;
    end if;

    -- Persist overrides before the keeper pre-fill so team_on_clock (which
    -- reads the row) routes traded picks to their real owner below.
    update public.drafts set pick_owner_overrides = overrides where id = p_draft_id;

    if kc > 0 and round_cost and team_count is not null and team_count > 0 then
        total_rounds := d.total_picks / team_count;
        for t in
            select tm.id, tm.keepers from public.teams tm
             where tm.league_id = d.league_id
               and coalesce(array_length(tm.keepers, 1), 0) > 0
        loop
            foreach k in array t.keepers loop
                select c.cost_round into cost
                  from public.keeper_round_costs(d.league_id) c
                 where c.player_id = k;
                cost := least(greatest(coalesce(cost, total_rounds), 1), total_rounds);

                pick_no := null;
                for r in reverse cost..1 loop
                    select p into pick_no
                      from generate_series((r - 1) * team_count + 1, r * team_count) p
                     where public.team_on_clock(d.id, p) = t.id
                       and not exists (select 1 from public.draft_picks dp
                                        where dp.draft_id = d.id and dp.pick_number = p)
                     limit 1;
                    if pick_no is not null then exit; end if;
                end loop;
                if pick_no is null then
                    for r in cost + 1..total_rounds loop
                        select p into pick_no
                          from generate_series((r - 1) * team_count + 1, r * team_count) p
                         where public.team_on_clock(d.id, p) = t.id
                           and not exists (select 1 from public.draft_picks dp
                                            where dp.draft_id = d.id and dp.pick_number = p)
                         limit 1;
                        if pick_no is not null then exit; end if;
                    end loop;
                end if;
                -- A team with more keepers than owned picks keeps the player
                -- on the roster without consuming a slot (degenerate config).
                if pick_no is null then continue; end if;

                insert into public.draft_picks (draft_id, pick_number, team_id, player_id, auto_pick)
                values (d.id, pick_no, t.id, k, false);
            end loop;
        end loop;
    end if;

    first_pick := public.next_open_pick(p_draft_id, 1);
    if first_pick is null then
        update public.drafts
           set status = 'complete',
               started_at = coalesce(started_at, now()),
               completed_at = now(),
               current_pick = d.total_picks + 1,
               pick_deadline = null,
               paused_at = null,
               paused_remaining = null
         where id = p_draft_id
         returning * into d;
    else
        update public.drafts
           set status = 'live',
               started_at = coalesce(started_at, now()),
               current_pick = first_pick,
               pick_deadline = now() + (d.pick_seconds || ' seconds')::interval,
               paused_at = null,
               paused_remaining = null
         where id = p_draft_id
         returning * into d;
    end if;
    return d;
end$$;
