-- Draft auto-pick mode. When a team's ID is in drafts.auto_pick_team_ids,
-- their picks fire automatically (client-side as soon as they're on the
-- clock, server-side via cron as a fallback). Timeout picks also lock the
-- team into this list, so a missed clock keeps drafting for them until they
-- manually toggle off.

alter table public.drafts
    add column if not exists auto_pick_team_ids text[] not null default '{}';

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

    -- Auth: team owner OR the league commissioner. Anyone can toggle their
    -- own team; commissioner can toggle any team in their league (which
    -- includes every bot in a Testing Environment league).
    select t.owner_id into team_owner from public.teams t where t.id = p_team_id;
    select l.creator_id into league_creator
        from public.leagues l where l.id = d.league_id;
    if coalesce(team_owner = auth.uid(), false) is false
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
