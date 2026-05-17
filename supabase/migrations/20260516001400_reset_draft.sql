-- Testing Environment resets need to also wipe the draft state. A reset
-- inside preseason (or a full reset) should bring the draft back to its
-- scheduled, unstarted form so the admin can re-run it.
--
-- The picks are deleted (which also frees up the players, since rosters
-- are restored from the week-0 snapshot separately). The drafts row is
-- pushed back to status='scheduled' with cleared timestamps and a fresh
-- starts_at a few seconds out so the room can be re-entered immediately.

create or replace function public.reset_draft(p_league_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
begin
    select * into d from public.drafts where league_id = p_league_id;
    if not found then return; end if;

    delete from public.draft_picks where draft_id = d.id;

    update public.drafts
       set status           = 'scheduled',
           current_pick     = 0,
           started_at       = null,
           completed_at     = null,
           pick_deadline    = null,
           paused_at        = null,
           paused_remaining = null,
           starts_at        = now() + interval '5 seconds'
     where id = d.id;
end$$;

-- Re-create reset_period to call reset_draft only when at the preseason
-- (week 0) — that's the period the draft belongs to.
create or replace function public.reset_period(p_league_id uuid)
returns public.leagues
language plpgsql security definer set search_path = public as $$
declare
    lg public.leagues;
    current_week int;
begin
    select * into lg from public.leagues where id = p_league_id for update;
    if not found or not coalesce(lg.is_test, false) then
        raise exception 'not a test league';
    end if;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the league creator can reset';
    end if;
    current_week := coalesce(lg.simulated_week, 0);

    delete from public.transactions    where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.trades          where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.waiver_claims   where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.dropped_players where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;

    update public.teams t
       set roster = s.roster, starters = s.starters
      from public.team_snapshots s
     where s.team_id = t.id
       and s.simulated_week = current_week
       and t.league_id = p_league_id;

    delete from public.team_snapshots
     where league_id = p_league_id and simulated_week > current_week;

    -- Preseason owns the draft — only reset it there.
    if current_week = 0 then
        perform public.reset_draft(p_league_id);
    end if;

    return lg;
end$$;

-- reset_all always resets the draft on top of everything else.
create or replace function public.reset_all(p_league_id uuid)
returns public.leagues
language plpgsql security definer set search_path = public as $$
declare
    lg public.leagues;
begin
    select * into lg from public.leagues where id = p_league_id for update;
    if not found or not coalesce(lg.is_test, false) then
        raise exception 'not a test league';
    end if;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the league creator can reset';
    end if;

    delete from public.transactions    where league_id = p_league_id;
    delete from public.trades          where league_id = p_league_id;
    delete from public.waiver_claims   where league_id = p_league_id;
    delete from public.dropped_players where league_id = p_league_id;

    update public.teams t
       set roster = s.roster, starters = s.starters
      from public.team_snapshots s
     where s.team_id = t.id
       and s.simulated_week = 0
       and t.league_id = p_league_id;

    delete from public.team_snapshots
     where league_id = p_league_id and simulated_week > 0;

    update public.leagues set simulated_week = 0 where id = p_league_id;

    perform public.reset_draft(p_league_id);

    select * into lg from public.leagues where id = p_league_id;
    return lg;
end$$;
