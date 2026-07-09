-- Guard make_pick against auction drafts. Auction rosters fill exclusively
-- through nominate_player/place_bid/settle_lot; a stray make_pick (e.g. an
-- auto-pick client racing a format change) would insert a pick row and
-- advance the nomination counter outside the lot machinery. Body is the
-- 20260713000100 version with the single format check added after the
-- status check.
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
