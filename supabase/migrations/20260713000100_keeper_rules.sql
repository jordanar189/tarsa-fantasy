-- Full keeper rules on top of keeper-lite (20260710000000):
--
--   • leagues.keeper_round_cost — when true, a keeper costs the team's draft
--     pick in the round the player went last season (escalating one round per
--     consecutive keep). The draft runs the FULL roster-size rounds; keeper
--     slots are pre-filled as draft_picks rows at start_draft and the pick
--     clock skips them (next_open_pick). When false, keeper-lite semantics
--     are unchanged: the draft just shrinks by keeper_count rounds.
--   • leagues.keeper_deadline — owners can set keepers only until this
--     instant (commissioner exempt). Null = until the draft starts, as before.
--   • keeper_round_costs(league) — player → cost round, derived from the
--     parent league's draft: round drafted, minus one if the player was also
--     a keeper there (escalation). Players with no parent pick row (waiver
--     adds, keeper-lite parents) fall back to the last round at start_draft.
--   • next_open_pick(draft, from) — smallest unfilled pick number; make_pick
--     and start_draft advance through it so pre-filled keeper picks are
--     skipped without any client-side special casing.

alter table public.leagues add column if not exists keeper_round_cost boolean not null default false;
alter table public.leagues add column if not exists keeper_deadline timestamptz;

-- 1. Cost lookup. One row per player drafted in the parent league's draft;
-- consumers (client display, start_draft) apply the last-round fallback.
create or replace function public.keeper_round_costs(p_league_id uuid)
returns table(player_id text, cost_round int)
language sql stable security definer set search_path = public as $$
    select dp.player_id,
           greatest(1,
               ((dp.pick_number - 1) / greatest(coalesce(array_length(pd.pick_order, 1), 1), 1) + 1)
               - case when exists (select 1 from public.teams pt
                                    where pt.league_id = l.parent_league_id
                                      and dp.player_id = any(pt.keepers))
                      then 1 else 0 end
           )::int
      from public.leagues l
      join public.drafts pd      on pd.league_id = l.parent_league_id
      join public.draft_picks dp on dp.draft_id = pd.id
     where l.id = p_league_id
       and public.is_league_member(p_league_id)
$$;

revoke execute on function public.keeper_round_costs(uuid) from public, anon;
grant  execute on function public.keeper_round_costs(uuid) to authenticated;

-- 2. Pick-clock helper: the smallest pick >= p_from with no draft_picks row,
-- null when the draft is exhausted.
create or replace function public.next_open_pick(p_draft_id uuid, p_from int)
returns int language sql stable as $$
    select min(n)
      from generate_series(greatest(p_from, 1),
                           (select d.total_picks from public.drafts d where d.id = p_draft_id)) n
     where not exists (select 1 from public.draft_picks dp
                        where dp.draft_id = p_draft_id and dp.pick_number = n)
$$;

-- 3. set_keepers: enforce the deadline for owners (commish exempt — they
-- handle late requests). Redefined from 20260710000000; the deadline block
-- is the only addition.
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

    if lg.keeper_deadline is not null and now() > lg.keeper_deadline
       and coalesce(lg.creator_id = auth.uid(), false) is false then
        raise exception 'keeper deadline has passed';
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

-- 4. start_draft: after the keeper trim and traded-pick override
-- materialization (both unchanged from 20260713000000), round-cost leagues
-- pre-fill each keeper into a pick the team owns in its cost round — bumping
-- earlier (more expensive) on collisions, later only when nothing earlier is
-- open — and the clock opens on the first unfilled pick.
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

    -- Traded picks → {pick_number: owner}. Only rounds inside the draft and
    -- only assets whose owner differs from the original slot matter.
    team_count := array_length(d.pick_order, 1);
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

-- 5. make_pick: advance through next_open_pick so pre-filled keeper picks are
-- skipped. Identical to a +1 walk in leagues without pre-fills. Redefined
-- from 20260710000000; only the advancement block changes.
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

-- 6. rollover_league: carry keeper_round_cost; keeper_deadline is per-season
-- and deliberately resets to null. Redefined from 20260713000000.
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
        scoring_settings, division_names, is_dynasty, keeper_count, tiebreaker,
        keeper_round_cost
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
        coalesce(parent.keeper_count, 0),
        coalesce(parent.tiebreaker, 'points_for'),
        coalesce(parent.keeper_round_cost, false)
    )
    returning * into child;

    if jsonb_typeof(p_teams) = 'array' and jsonb_array_length(p_teams) > 0 then
        insert into public.teams (
            id, league_id, name, owner_id, sort_index, division,
            roster, starters, ir, taxi, logo_url, color_hex, abbreviation,
            prior_team_id
        )
        select
            x.id, child.id, x.name, x.owner_id, x.sort_index, x.division,
            coalesce(x.roster, '{}'), coalesce(x.starters, '{}'),
            coalesce(x.ir, '{}'), coalesce(x.taxi, '{}'),
            x.logo_url, x.color_hex, x.abbreviation,
            x.prior_team_id
        from jsonb_to_recordset(p_teams) as x(
            id uuid, name text, owner_id uuid, sort_index int, division int,
            roster text[], starters text[], ir text[], taxi text[],
            logo_url text, color_hex text, abbreviation text,
            prior_team_id uuid
        );

        -- Translate the parent's pick assets for this season into the child
        -- league via the lineage mapping just written.
        insert into public.draft_pick_assets
            (league_id, season, round, original_team_id, owner_team_id)
        select child.id, a.season, a.round, orig.id, own.id
          from public.draft_pick_assets a
          join public.teams orig on orig.league_id = child.id
                                and orig.prior_team_id = a.original_team_id
          join public.teams own  on own.league_id = child.id
                                and own.prior_team_id = a.owner_team_id
         where a.league_id = p_parent_id
           and a.season = p_new_season
        on conflict (league_id, season, round, original_team_id) do nothing;
    end if;

    return child;
end$$;
