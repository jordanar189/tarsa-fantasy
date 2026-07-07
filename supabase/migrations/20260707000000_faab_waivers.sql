-- FAAB (free-agent acquisition budget) waivers, part 1: schema + claim RPC.
--
-- Leagues choose a waiver_mode: 'priority' (existing rolling-priority model)
-- or 'faab' (blind-bid budget). In FAAB mode every claim carries a bid;
-- resolution (bid desc, budget decrement) lands in the process_waivers
-- worker. teams.faab_spent accumulates winning bids across the season.
--
-- submit_waiver_claim replaces the client-side claim insert. The old path
-- computed team_priority as "pending count + 1" on the client, so two
-- concurrent submissions collided on the same priority; the RPC assigns it
-- under a row lock and validates FAAB bids against the remaining budget
-- (including what's already committed to other pending claims).

alter table public.leagues
    add column if not exists waiver_mode text    not null default 'priority',
    add column if not exists faab_budget integer not null default 100;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'leagues_waiver_mode_check'
          and conrelid = 'public.leagues'::regclass
    ) then
        alter table public.leagues
            add constraint leagues_waiver_mode_check
            check (waiver_mode in ('priority', 'faab'));
    end if;
end$$;

alter table public.teams
    add column if not exists faab_spent integer not null default 0;

-- Bid in league budget units; null on priority-mode claims.
alter table public.waiver_claims
    add column if not exists bid integer;

-- Winning FAAB bids ride along on the transaction row so a commissioner
-- rejection can refund the exact amount.
alter table public.transactions
    add column if not exists bid integer;

create or replace function public.submit_waiver_claim(
    p_league_id      uuid,
    p_team_id        uuid,
    p_add_player_id  text,
    p_drop_player_id text default null,
    p_bid            integer default null
) returns public.waiver_claims
language plpgsql security definer set search_path = public as $$
declare
    lg        public.leagues;
    tm        public.teams;
    committed integer;
    claim     public.waiver_claims;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found then raise exception 'league not found'; end if;

    -- Lock the team row: serializes concurrent submissions from the same
    -- team so team_priority assignment and the budget check are race-free.
    select * into tm from public.teams where id = p_team_id for update;
    if not found then raise exception 'team not found'; end if;
    if tm.league_id <> p_league_id then raise exception 'team is not in this league'; end if;
    if tm.owner_id is distinct from auth.uid() then
        raise exception 'only the team owner can submit a claim';
    end if;

    if exists (select 1 from public.waiver_claims c
               where c.team_id = p_team_id
                 and c.status = 'pending'
                 and c.add_player_id = p_add_player_id) then
        raise exception 'you already have a pending claim for this player';
    end if;

    if lg.waiver_mode = 'faab' then
        if p_bid is null or p_bid < 0 then
            raise exception 'FAAB claims need a bid of 0 or more';
        end if;
        select coalesce(sum(c.bid), 0) into committed
          from public.waiver_claims c
         where c.team_id = p_team_id and c.status = 'pending';
        if p_bid + committed > lg.faab_budget - tm.faab_spent then
            raise exception 'bid exceeds your remaining FAAB budget';
        end if;
    end if;

    insert into public.waiver_claims
        (league_id, team_id, add_player_id, drop_player_id, team_priority, bid)
    values (
        p_league_id, p_team_id, p_add_player_id, p_drop_player_id,
        (select coalesce(max(c.team_priority), 0) + 1
           from public.waiver_claims c
          where c.team_id = p_team_id and c.status = 'pending'),
        case when lg.waiver_mode = 'faab' then p_bid end
    )
    returning * into claim;
    return claim;
end$$;

grant execute on function public.submit_waiver_claim(uuid, uuid, text, text, integer) to authenticated;
