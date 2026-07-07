-- Server-side roster writes: add_free_agent / drop_roster_player RPCs plus a
-- guard trigger on teams.roster.
--
-- Until now every add/drop was a raw PostgREST UPDATE on teams with all
-- validation client-side. Consequences: two managers could add the same free
-- agent concurrently (no one-player-one-roster guarantee), a modified client
-- could add anyone (including players inside a waiver window, bypassing
-- pending claims), and roster size limits were advisory.
--
-- The RPCs validate and apply atomically while holding the league row lock,
-- which serializes all roster mutations within a league. The guard trigger
-- then closes the raw path: authenticated users can no longer change the
-- roster column directly unless they're the league commissioner (manual
-- roster tools, promotion writes) — everyone else goes through the RPCs,
-- the trade/draft RPCs (which mark themselves via mark_roster_write), or
-- the service-role workers.

-- Transaction-local flag our security-definer RPCs set so the guard trigger
-- can tell a sanctioned write from a raw table UPDATE.
create or replace function public.mark_roster_write() returns void
language plpgsql as $$
begin
    perform set_config('app.roster_write', 'rpc', true);
end$$;

-- Only the sanctioned security-definer functions (which run as the function
-- owner) may set the flag — a client must not be able to call it via
-- /rest/v1/rpc. PostgREST requests are single transactions anyway, but
-- belt-and-braces.
revoke execute on function public.mark_roster_write() from public, anon, authenticated;

create or replace function public.guard_roster_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if new.roster is distinct from old.roster
       and auth.role() = 'authenticated'
       and coalesce(current_setting('app.roster_write', true), '') <> 'rpc'
       and not exists (select 1 from public.leagues l
                       where l.id = new.league_id
                         and l.creator_id = auth.uid()) then
        raise exception 'roster changes go through add/drop, waivers, trades, or the draft';
    end if;
    return new;
end$$;

drop trigger if exists teams_guard_roster on public.teams;
create trigger teams_guard_roster
    before update on public.teams
    for each row execute function public.guard_roster_write();

-- Active roster capacity from the league's jsonb config. Mirrors
-- RosterConfig.totalSize: every starter slot (incl. flex variants) + bench.
create or replace function public.league_total_roster_size(cfg jsonb) returns integer
language sql immutable as $$
    select coalesce((cfg->>'qb')::int, 1) + coalesce((cfg->>'rb')::int, 2)
         + coalesce((cfg->>'wr')::int, 2) + coalesce((cfg->>'te')::int, 1)
         + coalesce((cfg->>'flex')::int, 1) + coalesce((cfg->>'superflex')::int, 0)
         + coalesce((cfg->>'wrFlex')::int, 0) + coalesce((cfg->>'recFlex')::int, 0)
         + coalesce((cfg->>'k')::int, 1) + coalesce((cfg->>'def')::int, 1)
         + coalesce((cfg->>'bench')::int, 6)
$$;

create or replace function public.add_free_agent(
    p_league_id      uuid,
    p_team_id        uuid,
    p_add_player_id  text,
    p_drop_player_id text default null,
    p_bid            integer default null
) returns public.teams
language plpgsql security definer set search_path = public as $$
declare
    lg           public.leagues;
    tm           public.teams;
    reserved     text[];
    new_roster   text[];
    new_starters text[];
    active_count integer;
begin
    -- League row lock: serializes every roster mutation in the league, which
    -- is what makes the one-player-one-roster check race-free.
    select * into lg from public.leagues where id = p_league_id for update;
    if not found then raise exception 'league not found'; end if;

    select * into tm from public.teams where id = p_team_id;
    if not found or tm.league_id <> p_league_id then
        raise exception 'team not found in this league';
    end if;
    if auth.role() = 'authenticated'
       and tm.owner_id is distinct from auth.uid()
       and lg.creator_id is distinct from auth.uid() then
        raise exception 'only the team owner or commissioner can change this roster';
    end if;

    if exists (select 1 from public.teams t
               where t.league_id = p_league_id
                 and p_add_player_id = any (t.roster)) then
        raise exception 'player is already on a roster in this league';
    end if;
    -- Inside an active waiver window the player belongs to the claims
    -- process, not instant adds (this closes the window-vs-tick loophole).
    if exists (select 1 from public.dropped_players dp
               where dp.league_id = p_league_id
                 and dp.player_id = p_add_player_id
                 and dp.waiver_until > now()) then
        raise exception 'player is on waivers — submit a claim instead';
    end if;

    new_roster := tm.roster;
    if p_drop_player_id is not null then
        if not (p_drop_player_id = any (new_roster)) then
            raise exception 'drop player is not on this roster';
        end if;
        new_roster := array_remove(new_roster, p_drop_player_id);
    end if;
    if not (p_add_player_id = any (new_roster)) then
        new_roster := new_roster || p_add_player_id;
    end if;

    -- IR always sits outside the active roster; taxi only while configured.
    reserved := coalesce(tm.ir, '{}');
    if coalesce((lg.roster_config->>'taxi')::int, 0) > 0 then
        reserved := reserved || coalesce(tm.taxi, '{}');
    end if;
    select count(*) into active_count
      from unnest(new_roster) p where not (p = any (reserved));
    if active_count > public.league_total_roster_size(lg.roster_config) then
        raise exception 'roster is full — choose a player to drop';
    end if;

    -- Starters are slot-positional: blank the dropped player's slot in place.
    select coalesce(array_agg(case when s = p_drop_player_id then '' else s end
                              order by ord), '{}')
      into new_starters
      from unnest(tm.starters) with ordinality as u(s, ord);

    perform public.mark_roster_write();
    -- The dropped player also leaves IR/taxi — a phantom entry there would
    -- inflate the slot counts and block future placements.
    update public.teams
       set roster = new_roster, starters = new_starters,
           ir   = array_remove(coalesce(tm.ir,   '{}'), p_drop_player_id),
           taxi = array_remove(coalesce(tm.taxi, '{}'), p_drop_player_id)
     where id = p_team_id
     returning * into tm;

    if p_drop_player_id is not null then
        insert into public.dropped_players (league_id, player_id, dropped_at, waiver_until)
        values (p_league_id, p_drop_player_id, now(),
                now() + (lg.waiver_period_hours || ' hours')::interval)
        on conflict (league_id, player_id)
        do update set dropped_at = excluded.dropped_at,
                      waiver_until = excluded.waiver_until;
    end if;

    insert into public.transactions
        (league_id, team_id, kind, add_player_id, drop_player_id, status, bid)
    values (p_league_id, p_team_id,
            case when p_drop_player_id is null then 'add' else 'add_drop' end,
            p_add_player_id, p_drop_player_id, 'completed', p_bid);

    return tm;
end$$;

create or replace function public.drop_roster_player(
    p_league_id uuid,
    p_team_id   uuid,
    p_player_id text
) returns public.teams
language plpgsql security definer set search_path = public as $$
declare
    lg           public.leagues;
    tm           public.teams;
    new_starters text[];
begin
    select * into lg from public.leagues where id = p_league_id for update;
    if not found then raise exception 'league not found'; end if;

    select * into tm from public.teams where id = p_team_id;
    if not found or tm.league_id <> p_league_id then
        raise exception 'team not found in this league';
    end if;
    if auth.role() = 'authenticated'
       and tm.owner_id is distinct from auth.uid()
       and lg.creator_id is distinct from auth.uid() then
        raise exception 'only the team owner or commissioner can change this roster';
    end if;
    if not (p_player_id = any (tm.roster)) then
        raise exception 'player is not on this roster';
    end if;

    select coalesce(array_agg(case when s = p_player_id then '' else s end
                              order by ord), '{}')
      into new_starters
      from unnest(tm.starters) with ordinality as u(s, ord);

    perform public.mark_roster_write();
    update public.teams
       set roster = array_remove(tm.roster, p_player_id),
           starters = new_starters,
           ir   = array_remove(coalesce(tm.ir,   '{}'), p_player_id),
           taxi = array_remove(coalesce(tm.taxi, '{}'), p_player_id)
     where id = p_team_id
     returning * into tm;

    insert into public.dropped_players (league_id, player_id, dropped_at, waiver_until)
    values (p_league_id, p_player_id, now(),
            now() + (lg.waiver_period_hours || ' hours')::interval)
    on conflict (league_id, player_id)
    do update set dropped_at = excluded.dropped_at,
                  waiver_until = excluded.waiver_until;

    insert into public.transactions
        (league_id, team_id, kind, add_player_id, drop_player_id, status)
    values (p_league_id, p_team_id, 'drop', null, p_player_id, 'completed');

    return tm;
end$$;

grant execute on function public.add_free_agent(uuid, uuid, text, text, integer) to authenticated;
grant execute on function public.drop_roster_player(uuid, uuid, text) to authenticated;

-- make_pick appends to teams.roster from a security-definer context whose
-- caller is an ordinary owner, so it must mark itself for the guard trigger.
-- Redefined verbatim from 20260516000600_drafts.sql with the one added line.
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
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found                   then raise exception 'draft not found'; end if;
    if d.status <> 'live'          then raise exception 'draft is not live'; end if;
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

    insert into public.draft_picks (draft_id, pick_number, team_id, player_id, auto_pick)
    values (p_draft_id, d.current_pick, p_team_id, p_player_id, p_is_auto);

    -- Append to the team's roster row (sanctioned write — see guard trigger).
    perform public.mark_roster_write();
    update public.teams
       set roster = array_append(roster, p_player_id)
     where id = p_team_id;

    next_pick    := d.current_pick + 1;
    new_deadline := now() + (d.pick_seconds || ' seconds')::interval;

    if next_pick > d.total_picks then
        update public.drafts
           set current_pick = next_pick,
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
