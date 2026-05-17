-- Allow the service role (auth.uid() = null) to call set_auto_pick. Needed
-- because draft_tick locks a team into auto mode after timing them out, and
-- the edge function runs unauthenticated.

create or replace function public.set_auto_pick(
    p_draft_id uuid,
    p_team_id  uuid,
    p_enabled  boolean
) returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    team_owner uuid;
    league_creator uuid;
    new_list text[];
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;

    select t.owner_id into team_owner from public.teams t where t.id = p_team_id;
    select l.creator_id into league_creator
        from public.leagues l where l.id = d.league_id;

    -- auth.uid() IS NULL means the service role is calling (edge function).
    -- An authenticated user must be the team owner or the league commish.
    if auth.uid() is not null
       and coalesce(team_owner = auth.uid(), false) is false
       and coalesce(league_creator = auth.uid(), false) is false then
        raise exception 'not authorized to toggle auto-pick for this team';
    end if;

    if p_enabled then
        if not (d.auto_pick_team_ids @> array[p_team_id::text]) then
            new_list := d.auto_pick_team_ids || array[p_team_id::text];
        else
            new_list := d.auto_pick_team_ids;
        end if;
    else
        select array_agg(x) into new_list
          from unnest(d.auto_pick_team_ids) x
         where x <> p_team_id::text;
        new_list := coalesce(new_list, '{}'::text[]);
    end if;

    update public.drafts set auto_pick_team_ids = new_list
     where id = p_draft_id returning * into d;
    return d;
end$$;
