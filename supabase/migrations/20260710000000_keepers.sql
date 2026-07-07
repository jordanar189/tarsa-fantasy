-- Keeper-lite: leagues get a keeper_count; owners pick keepers from their
-- (carried-over) roster before the draft via set_keepers; start_draft trims
-- each roster down to its keepers; kept players are excluded from the draft
-- pool (make_pick rejects them, draft_tick and the clients filter them).
-- Keepers act as a team's earliest "picks": the draft shrinks by
-- keeper_count rounds and rosters still land on the configured size.
-- Round-cost keepers are deliberately out of scope (Phase 7).
--
-- Also fixes a rollover gap while redefining rollover_league: the child
-- league insert predates the FAAB columns, so waiver_mode / faab_budget
-- silently reset to defaults on every rollover.

alter table public.leagues add column if not exists keeper_count int not null default 0;
alter table public.teams   add column if not exists keepers text[] not null default '{}';

-- 1. Extend the raw-write guard to keepers. Owners could otherwise write the
-- column directly and skip the count/roster/draft-state validation below.
-- Commissioner writes stay exempt, same as roster.
create or replace function public.guard_roster_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if (new.roster is distinct from old.roster
        or new.keepers is distinct from old.keepers)
       and auth.role() = 'authenticated'
       and coalesce(current_setting('app.roster_write', true), '') <> 'rpc'
       and not exists (select 1 from public.leagues l
                       where l.id = new.league_id
                         and l.creator_id = auth.uid()) then
        raise exception 'roster changes go through add/drop, waivers, trades, or the draft';
    end if;
    return new;
end$$;

-- 2. RPC: set_keepers. Owner (or commish) picks up to keeper_count players
-- off the team's current roster, only while the draft hasn't started.
create or replace function public.set_keepers(
    p_league_id uuid,
    p_team_id   uuid,
    p_keepers   text[]
) returns void
language plpgsql security definer set search_path = public as $$
declare
    lg public.leagues;
    tm public.teams;
    d_status text;
    ks text[] := '{}';
    k  text;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found then raise exception 'league not found'; end if;
    select * into tm from public.teams
     where id = p_team_id and league_id = p_league_id
     for update;
    if not found then raise exception 'team not found'; end if;

    if coalesce(tm.owner_id = auth.uid(), false) is false
       and coalesce(lg.creator_id = auth.uid(), false) is false then
        raise exception 'not authorized to set keepers for this team';
    end if;
    if lg.keeper_count <= 0 then
        raise exception 'league has no keeper slots';
    end if;

    select d.status into d_status
      from public.drafts d where d.league_id = p_league_id;
    if d_status is not null and d_status <> 'scheduled' then
        raise exception 'keepers are locked once the draft starts';
    end if;

    -- Dedup, drop empties, and require every keeper to be on the roster.
    foreach k in array coalesce(p_keepers, '{}'::text[]) loop
        if k is null or k = '' or k = any(ks) then continue; end if;
        if not (k = any(tm.roster)) then
            raise exception 'keeper % is not on this roster', k;
        end if;
        ks := array_append(ks, k);
    end loop;
    if coalesce(array_length(ks, 1), 0) > lg.keeper_count then
        raise exception 'too many keepers (max %)', lg.keeper_count;
    end if;

    perform public.mark_roster_write();
    update public.teams set keepers = ks where id = p_team_id;
end$$;

revoke execute on function public.set_keepers(uuid, uuid, text[]) from public, anon;
grant  execute on function public.set_keepers(uuid, uuid, text[]) to authenticated;

-- 3. start_draft: in keeper leagues, trim every roster down to its keepers
-- the moment the draft goes live — everyone else re-enters the pool. The
-- keepers column is intersected with the roster too, so a player traded away
-- after being marked keeper doesn't come back from the dead. Redefined from
-- 20260516000600_drafts.sql with the keeper block added.
create or replace function public.start_draft(p_draft_id uuid)
returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    is_commish boolean;
    kc int;
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

    select coalesce(l.keeper_count, 0) into kc
        from public.leagues l where l.id = d.league_id;
    if kc > 0 then
        perform public.mark_roster_write();
        update public.teams t
           set keepers  = (select coalesce(array_agg(x), '{}'::text[])
                             from unnest(t.keepers) x where x = any(t.roster)),
               roster   = (select coalesce(array_agg(x), '{}'::text[])
                             from unnest(t.roster) x where x = any(t.keepers)),
               starters = '{}',
               ir       = (select coalesce(array_agg(x), '{}'::text[])
                             from unnest(t.ir) x where x = any(t.keepers)),
               taxi     = (select coalesce(array_agg(x), '{}'::text[])
                             from unnest(t.taxi) x where x = any(t.keepers))
         where t.league_id = d.league_id;
    end if;

    update public.drafts
       set status = 'live',
           started_at = coalesce(started_at, now()),
           current_pick = 1,
           pick_deadline = now() + (d.pick_seconds || ' seconds')::interval,
           paused_at = null,
           paused_remaining = null
     where id = p_draft_id
     returning * into d;
    return d;
end$$;

-- 4. make_pick: kept players are not draftable. Redefined from
-- 20260708000200_roster_rpcs.sql with the one added check.
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

    -- Keepers never re-enter the pool.
    if exists (select 1 from public.teams t
               where t.league_id = d.league_id
                 and p_player_id = any(t.keepers)) then
        raise exception 'player is a keeper and not draftable';
    end if;

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

-- 5. rollover_league: carry keeper_count — and the FAAB columns the previous
-- definition silently dropped (waiver_mode/faab_budget reset on rollover).
-- teams.keepers deliberately does NOT carry: keeper choices are per-season,
-- made fresh before each draft. Redefined from
-- 20260610000000_rollover_carry_taxi_and_weeks_per_round.sql.
create or replace function public.rollover_league(
    p_parent_id       uuid,
    p_new_season      int,
    p_new_name        text,
    p_schedule        jsonb  default '[]'::jsonb,
    p_waiver_priority text[] default '{}'::text[],
    p_teams           jsonb  default '[]'::jsonb
) returns public.leagues
language plpgsql security definer set search_path = public as $$
declare
    parent     public.leagues;
    is_commish boolean;
    child      public.leagues;
    new_code   text;
begin
    select * into parent from public.leagues where id = p_parent_id;
    if not found then raise exception 'parent league not found'; end if;
    select (parent.creator_id = auth.uid()) into is_commish;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can roll over the league';
    end if;

    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));

    insert into public.leagues (
        name, season, scoring, creator_id, roster_config, schedule, join_code,
        waiver_process_day, waiver_process_hour, waiver_period_hours,
        commissioner_approval, waiver_priority,
        waiver_mode, faab_budget,
        trade_approval, trade_deadline, trade_vote_hours,
        parent_league_id,
        regular_season_weeks, playoff_teams, playoff_reseed, weeks_per_round,
        scoring_settings, division_names, is_dynasty, keeper_count
    ) values (
        coalesce(nullif(p_new_name, ''), parent.name),
        p_new_season,
        parent.scoring,
        parent.creator_id,
        parent.roster_config,
        coalesce(p_schedule, '[]'::jsonb),
        new_code,
        parent.waiver_process_day,
        parent.waiver_process_hour,
        parent.waiver_period_hours,
        parent.commissioner_approval,
        coalesce(p_waiver_priority, '{}'::text[]),
        parent.waiver_mode,
        parent.faab_budget,
        parent.trade_approval,
        null,
        parent.trade_vote_hours,
        parent.id,
        parent.regular_season_weeks,
        parent.playoff_teams,
        parent.playoff_reseed,
        parent.weeks_per_round,
        parent.scoring_settings,
        parent.division_names,
        parent.is_dynasty,
        coalesce(parent.keeper_count, 0)
    )
    returning * into child;

    if jsonb_typeof(p_teams) = 'array' and jsonb_array_length(p_teams) > 0 then
        insert into public.teams (
            id, league_id, name, owner_id, sort_index, division,
            roster, starters, ir, taxi, logo_url, color_hex, abbreviation
        )
        select
            x.id, child.id, x.name, x.owner_id, x.sort_index, x.division,
            coalesce(x.roster, '{}'), coalesce(x.starters, '{}'),
            coalesce(x.ir, '{}'), coalesce(x.taxi, '{}'),
            x.logo_url, x.color_hex, x.abbreviation
        from jsonb_to_recordset(p_teams) as x(
            id uuid, name text, owner_id uuid, sort_index int, division int,
            roster text[], starters text[], ir text[], taxi text[],
            logo_url text, color_hex text, abbreviation text
        );
    end if;

    return child;
end$$;
