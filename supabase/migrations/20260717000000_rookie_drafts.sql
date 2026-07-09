-- Rookie-only drafts (dynasty offseason). A rookie draft is the rolled-over
-- child league's draft with pool = 'rookies': rosters carried over from the
-- parent season stay untouched (SUPPLEMENTAL — no keeper roster-trim, no
-- keeper pre-fill), total_picks is rounds × teams as sent by setup, and
-- make_pick/draft_tick only accept rookies. Traded-pick ordering needs no
-- new code: start_draft's existing draft_pick_assets materialization routes
-- any traded slot inside the draft's rounds to its owner, so a dealt 2027
-- 1st shows up exactly where it should.
--
-- Rookie = players_cache.years_exp = 0, falling back to draft_year =
-- league season when experience is missing for a player.

alter table public.drafts
    add column if not exists pool text not null default 'all';   -- 'all' | 'rookies'

create or replace function public.is_rookie(p_player_id text, p_season int)
returns boolean language sql stable as $$
    select exists (
        select 1 from public.players_cache pc
         where pc.id = p_player_id
           and (pc.years_exp = 0
                or (pc.years_exp is null and pc.draft_year = p_season))
    )
$$;

-- make_pick: 20260716000000 body + the rookie-pool check (after the keeper
-- check, before the insert).
create or replace function public.make_pick(
    p_draft_id   uuid,
    p_team_id    uuid,
    p_player_id  text,
    p_is_auto    boolean default false
) returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d            public.drafts;
    team_on_clock uuid;
    next_pick    int;
    new_deadline timestamptz;
    is_owner     boolean;
    is_commish   boolean;
    lg_season    int;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found                   then raise exception 'draft not found'; end if;
    if d.status <> 'live'          then raise exception 'draft is not live'; end if;
    if d.format = 'auction' then
        raise exception 'auction drafts fill through nomination and bidding';
    end if;
    if d.current_pick < 1
       or d.current_pick > d.total_picks
    then raise exception 'no pick is currently active'; end if;

    team_on_clock := public.team_on_clock(d.id, d.current_pick);
    if team_on_clock is null
       or team_on_clock <> p_team_id
    then raise exception 'team is not on the clock'; end if;

    -- Auth: owner of the team, or the league commissioner, or auto-pick.
    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if not p_is_auto
       and coalesce(is_owner, false) is false
       and coalesce(is_commish, false) is false
    then raise exception 'not authorized to pick for this team'; end if;

    -- Keepers never re-enter the pool.
    if exists (select 1 from public.teams t
               where t.league_id = d.league_id
                 and p_player_id = any(t.keepers)) then
        raise exception 'player is a keeper and not draftable';
    end if;

    -- Rookie drafts only accept the incoming class.
    if d.pool = 'rookies' then
        select l.season into lg_season from public.leagues l where l.id = d.league_id;
        if not public.is_rookie(p_player_id, lg_season) then
            raise exception 'only rookies are draftable in this draft';
        end if;
    end if;

    insert into public.draft_picks (draft_id, pick_number, team_id, player_id, auto_pick)
    values (p_draft_id, d.current_pick, p_team_id, p_player_id, p_is_auto);

    -- Append to the team's roster row (sanctioned write — see guard trigger).
    perform public.mark_roster_write();
    update public.teams
       set roster = array_append(roster, p_player_id)
     where id = p_team_id;

    next_pick    := public.next_open_pick(p_draft_id, d.current_pick + 1);
    new_deadline := now() + (d.pick_seconds || ' seconds')::interval;

    if next_pick is null then
        update public.drafts
           set current_pick = d.total_picks + 1,
               pick_deadline = null,
               status = 'complete',
               completed_at = now()
         where id = p_draft_id
         returning * into d;
    else
        update public.drafts
           set current_pick = next_pick,
               pick_deadline = new_deadline
         where id = p_draft_id
         returning * into d;
    end if;
    return d;
end$$;

-- start_draft: 20260715000000 body with one addition — a rookie draft is
-- supplemental, so the keeper machinery (roster trim, round-cost pre-fill,
-- auction $1 pre-fill) is skipped wholesale by zeroing kc. Carried rosters
-- stay exactly as rollover left them; traded-pick overrides still apply.
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
    -- Rookie drafts are a short supplemental snake/linear format; none of
    -- the auction machinery (nomination pool, total_picks normalization,
    -- draft_tick auto-nomination) is rookie-aware, so the combination is
    -- rejected outright rather than silently escaping the rookie-only rule.
    if d.pool = 'rookies' and d.format = 'auction' then
        raise exception 'rookie drafts run as snake or linear, not auction';
    end if;

    select coalesce(l.keeper_count, 0), l.season, coalesce(l.keeper_round_cost, false)
      into kc, lg_season, round_cost
      from public.leagues l where l.id = d.league_id;
    -- Supplemental rookie drafts leave carried rosters alone.
    if d.pool = 'rookies' then kc := 0; end if;
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
