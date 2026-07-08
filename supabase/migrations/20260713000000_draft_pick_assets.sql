-- Draft-pick trading (dynasty): future-season picks become assets that ride
-- through the existing trade engine.
--
--   • teams.prior_team_id — lineage across rollover (new ids are minted each
--     season; this links a team to its previous-season self). Used to
--     translate pick assets into the child league and, later, for all-time
--     franchise records.
--   • draft_pick_assets — one row per (league, season, round, original slot).
--     owner_team_id moves on trade; original_team_id never changes (that's
--     whose schedule position the pick occupies).
--   • ensure_pick_assets(league, season, rounds) — commish generator.
--   • propose_trade / attempt_execute_trade — redefined to carry and swap
--     pick assets alongside players.
--   • drafts.pick_owner_overrides — {pick_number: team_id} materialized at
--     start_draft from traded assets; team_on_clock consults it, so
--     make_pick, draft_tick, and the client all route traded picks to the
--     new owner from one source of truth.
--   • rollover_league — redefined to stamp prior_team_id and translate the
--     parent's assets for the new season into the child league.

alter table public.teams  add column if not exists prior_team_id uuid;
alter table public.drafts add column if not exists pick_owner_overrides jsonb not null default '{}'::jsonb;

create table if not exists public.draft_pick_assets (
    id               uuid primary key default gen_random_uuid(),
    league_id        uuid not null references public.leagues(id) on delete cascade,
    season           int  not null,
    round            int  not null,
    original_team_id uuid not null references public.teams(id) on delete cascade,
    owner_team_id    uuid not null references public.teams(id) on delete cascade,
    created_at       timestamptz not null default now(),
    unique (league_id, season, round, original_team_id)
);
create index if not exists draft_pick_assets_owner_idx
    on public.draft_pick_assets (league_id, owner_team_id);

alter table public.draft_pick_assets enable row level security;
drop policy if exists "pick_assets_read" on public.draft_pick_assets;
create policy "pick_assets_read"
    on public.draft_pick_assets for select
    using (public.is_league_member(league_id));

-- 1. Generator: one asset per team × round for a future draft season.
-- Idempotent (on conflict do nothing), commissioner-only.
create or replace function public.ensure_pick_assets(
    p_league_id uuid,
    p_season    int,
    p_rounds    int default 4
) returns int
language plpgsql security definer set search_path = public as $$
declare
    lg public.leagues;
    n  int;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found then raise exception 'league not found'; end if;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the commissioner can generate pick assets';
    end if;
    if p_season < lg.season then
        raise exception 'pick season is in the past';
    end if;
    if p_rounds < 1 or p_rounds > 30 then
        raise exception 'rounds out of range';
    end if;

    insert into public.draft_pick_assets (league_id, season, round, original_team_id, owner_team_id)
    select p_league_id, p_season, r, t.id, t.id
      from public.teams t
     cross join generate_series(1, p_rounds) r
     where t.league_id = p_league_id
    on conflict (league_id, season, round, original_team_id) do nothing;
    get diagnostics n = row_count;
    return n;
end$$;

revoke execute on function public.ensure_pick_assets(uuid, int, int) from public, anon;
grant  execute on function public.ensure_pick_assets(uuid, int, int) to authenticated;

-- 2. Trades carry pick assets. Empty arrays keep the existing player-only
-- flow byte-identical.
alter table public.trades add column if not exists proposer_pick_ids  uuid[] not null default '{}';
alter table public.trades add column if not exists recipient_pick_ids uuid[] not null default '{}';

-- 3. propose_trade with pick params. The old 7-arg signature is dropped so
-- there's exactly one definition; the client always sends the full set.
drop function if exists public.propose_trade(uuid, uuid, uuid, text[], text[], text, uuid);
create or replace function public.propose_trade(
    p_league_id            uuid,
    p_proposer_team_id     uuid,
    p_recipient_team_id    uuid,
    p_proposer_player_ids  text[],
    p_recipient_player_ids text[],
    p_note                 text default null,
    p_parent_trade_id      uuid default null,
    p_proposer_pick_ids    uuid[] default '{}',
    p_recipient_pick_ids   uuid[] default '{}'
) returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    lg        public.leagues;
    proposer  public.teams;
    recipient public.teams;
    t         public.trades;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found then raise exception 'league not found'; end if;
    if lg.trade_deadline is not null and now() > lg.trade_deadline then
        raise exception 'trade deadline has passed';
    end if;

    select * into proposer from public.teams
        where id = p_proposer_team_id and league_id = p_league_id;
    if not found then raise exception 'proposer team not in league'; end if;
    select * into recipient from public.teams
        where id = p_recipient_team_id and league_id = p_league_id;
    if not found then raise exception 'recipient team not in league'; end if;

    if proposer.owner_id is distinct from auth.uid() then
        raise exception 'only the team owner can propose a trade';
    end if;
    if recipient.owner_id is null then
        raise exception 'recipient team has no owner';
    end if;
    if p_proposer_team_id = p_recipient_team_id then
        raise exception 'cannot trade with yourself';
    end if;
    if (coalesce(array_length(p_proposer_player_ids, 1), 0)
        + coalesce(array_length(p_proposer_pick_ids, 1), 0)) = 0
       and (coalesce(array_length(p_recipient_player_ids, 1), 0)
        + coalesce(array_length(p_recipient_pick_ids, 1), 0)) = 0 then
        raise exception 'trade must include at least one player or pick';
    end if;

    if coalesce(array_length(p_proposer_player_ids, 1), 0) > 0
       and not (proposer.roster @> p_proposer_player_ids) then
        raise exception 'proposer does not roster all offered players';
    end if;
    if coalesce(array_length(p_recipient_player_ids, 1), 0) > 0
       and not (recipient.roster @> p_recipient_player_ids) then
        raise exception 'recipient does not roster all requested players';
    end if;

    perform public.validate_trade_picks(p_league_id, p_proposer_team_id,  p_proposer_pick_ids);
    perform public.validate_trade_picks(p_league_id, p_recipient_team_id, p_recipient_pick_ids);

    insert into public.trades (
        league_id, proposer_team_id, recipient_team_id,
        proposer_player_ids, recipient_player_ids,
        proposer_pick_ids, recipient_pick_ids,
        note, parent_trade_id, status
    ) values (
        p_league_id, p_proposer_team_id, p_recipient_team_id,
        coalesce(p_proposer_player_ids, '{}'),
        coalesce(p_recipient_player_ids, '{}'),
        coalesce(p_proposer_pick_ids, '{}'),
        coalesce(p_recipient_pick_ids, '{}'),
        nullif(p_note, ''), p_parent_trade_id, 'pending'
    ) returning * into t;

    if p_parent_trade_id is not null then
        update public.trades
           set status = 'countered', resolved_at = now()
         where id = p_parent_trade_id and status = 'pending';
    end if;
    return t;
end$$;

revoke execute on function public.propose_trade(uuid, uuid, uuid, text[], text[], text, uuid, uuid[], uuid[]) from public, anon;
grant  execute on function public.propose_trade(uuid, uuid, uuid, text[], text[], text, uuid, uuid[], uuid[]) to authenticated;

-- Every offered pick must exist in this league, be owned by the offering
-- team, and belong to a draft that hasn't started (a same-season asset is
-- tradeable only while the league's draft is still scheduled/absent).
create or replace function public.validate_trade_picks(
    p_league_id uuid, p_team_id uuid, p_pick_ids uuid[]
) returns void
language plpgsql stable security definer set search_path = public as $$
declare
    n int;
    lg_season int;
    d_status text;
begin
    if coalesce(array_length(p_pick_ids, 1), 0) = 0 then return; end if;

    select count(*) into n from public.draft_pick_assets a
     where a.id = any(p_pick_ids)
       and a.league_id = p_league_id
       and a.owner_team_id = p_team_id;
    if n <> array_length(p_pick_ids, 1) then
        raise exception 'team does not own all offered picks';
    end if;

    select l.season into lg_season from public.leagues l where l.id = p_league_id;
    if exists (select 1 from public.draft_pick_assets a
                where a.id = any(p_pick_ids) and a.season <= lg_season) then
        select d.status into d_status from public.drafts d where d.league_id = p_league_id;
        if d_status is not null and d_status <> 'scheduled' then
            raise exception 'current-season picks are locked once the draft starts';
        end if;
    end if;
end$$;

revoke execute on function public.validate_trade_picks(uuid, uuid, uuid[]) from public, anon, authenticated;

-- 4. attempt_execute_trade: re-validate + swap pick ownership alongside the
-- roster swap. Redefined from 20260708000300_trade_lock_fix.sql; the added
-- blocks are the pick re-validation and the two owner updates.
create or replace function public.attempt_execute_trade(p_trade_id uuid)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t         public.trades;
    proposer  public.teams;
    recipient public.teams;
    locked_player text;
    new_proposer_roster  text[];
    new_recipient_roster text[];
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending_execution' then return t; end if;

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

-- 5. team_on_clock honors traded picks via the overrides map materialized at
-- draft start. Redefined from 20260516000600_drafts.sql.
create or replace function public.team_on_clock(p_draft_id uuid, p_pick int)
returns uuid language plpgsql stable as $$
declare
    d         public.drafts;
    team_count int;
    round_idx  int;
    pos_in_round int;
    team_id_text text;
    override_id  text;
begin
    select * into d from public.drafts where id = p_draft_id;
    if not found or p_pick < 1 then return null; end if;

    override_id := d.pick_owner_overrides ->> p_pick::text;
    if override_id is not null then return override_id::uuid; end if;

    team_count := array_length(d.pick_order, 1);
    if team_count is null or team_count = 0 then return null; end if;

    round_idx    := (p_pick - 1) / team_count;
    pos_in_round := (p_pick - 1) % team_count;

    if d.format = 'snake' and (round_idx % 2 = 1) then
        pos_in_round := team_count - 1 - pos_in_round;
    end if;

    team_id_text := d.pick_order[pos_in_round + 1];
    return team_id_text::uuid;
exception when others then
    return null;
end$$;

-- 6. start_draft: materialize traded-pick overrides for this league's season
-- before going live. Redefined from 20260710000000_keepers.sql; the keeper
-- trim block is unchanged.
create or replace function public.start_draft(p_draft_id uuid)
returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    is_commish boolean;
    kc int;
    lg_season int;
    team_count int;
    overrides jsonb := '{}'::jsonb;
    a record;
    pick_no int;
    pos int;
    r int;
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

    select coalesce(l.keeper_count, 0), l.season into kc, lg_season
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

    update public.drafts
       set status = 'live',
           started_at = coalesce(started_at, now()),
           current_pick = 1,
           pick_deadline = now() + (d.pick_seconds || ' seconds')::interval,
           pick_owner_overrides = overrides,
           paused_at = null,
           paused_remaining = null
     where id = p_draft_id
     returning * into d;
    return d;
end$$;

-- 7. rollover_league: stamp prior_team_id on the child teams and translate
-- the parent's pick assets for the new season into the child league.
-- Redefined from 20260712000100_league_tiebreaker.sql.
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
        scoring_settings, division_names, is_dynasty, keeper_count, tiebreaker
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
        coalesce(parent.tiebreaker, 'points_for')
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
