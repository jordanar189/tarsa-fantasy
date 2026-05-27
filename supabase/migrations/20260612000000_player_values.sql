-- Owner-assigned player "value" ratings (high / medium / low). One row per
-- (team, player) — only the team's owner can set the value, but every league
-- member can read it. Rows are deleted (not archived) when the player leaves
-- the team's roster, mirroring the nickname trigger pattern but without
-- history retention — values are transient sentiment, not flavor text.

create table if not exists public.player_values (
    league_id  uuid not null references public.leagues(id) on delete cascade,
    team_id    uuid not null references public.teams(id)   on delete cascade,
    player_id  text not null,
    value      text not null check (value in ('high', 'medium', 'low')),
    updated_at timestamptz not null default now(),
    updated_by uuid default auth.uid(),
    primary key (team_id, player_id)
);

create index if not exists player_values_league_idx
    on public.player_values (league_id);
create index if not exists player_values_player_idx
    on public.player_values (player_id);

-- RLS: league members can read; writes go exclusively through the RPC.
alter table public.player_values enable row level security;

drop policy if exists "player_values_read" on public.player_values;
create policy "player_values_read" on public.player_values
    for select using (public.is_league_member(league_id));

-- Clear values whose player has left the roster. Mirrors the nickname trigger:
-- fires on every teams.roster change so drops/trades/waivers/resets uniformly
-- prune stale entries. Values are deleted outright (no history kept).
create or replace function public.clear_dropped_values()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if NEW.roster is distinct from OLD.roster then
        delete from public.player_values
         where team_id = NEW.id
           and not (player_id = any(NEW.roster));
    end if;
    return NEW;
end;
$$;

drop trigger if exists teams_clear_values on public.teams;
create trigger teams_clear_values
    after update on public.teams
    for each row
    execute function public.clear_dropped_values();

-- Set / update / clear a player's value. Pass NULL or an empty string to
-- clear. Caller must own the team (or be the league commissioner) and the
-- player must currently be on the team's roster.
create or replace function public.set_player_value(
    p_team_id   uuid,
    p_player_id text,
    p_value     text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_league_id uuid;
    v_owner     uuid;
    v_creator   uuid;
    v_clean     text;
    v_on_roster boolean;
begin
    select t.league_id, t.owner_id into v_league_id, v_owner
      from public.teams t where t.id = p_team_id;
    if v_league_id is null then
        raise exception 'team not found';
    end if;

    select l.creator_id into v_creator
      from public.leagues l where l.id = v_league_id;

    if auth.uid() is distinct from v_owner and auth.uid() is distinct from v_creator then
        raise exception 'not authorized to set values on this team';
    end if;

    select exists (
        select 1 from public.teams t
         where t.id = p_team_id and p_player_id = any(t.roster)
    ) into v_on_roster;

    v_clean := nullif(btrim(lower(coalesce(p_value, ''))), '');

    if v_clean is null then
        -- Clears are always safe: if the row exists (e.g. the player was
        -- just dropped and the trigger already pruned it, or it never
        -- existed) the delete is a no-op. Skipping the roster check here
        -- keeps stale-roster save paths from blowing up.
        delete from public.player_values
         where team_id = p_team_id and player_id = p_player_id;
    else
        if not v_on_roster then
            raise exception 'player is not on this team''s roster';
        end if;
        if v_clean not in ('high', 'medium', 'low') then
            raise exception 'value must be one of high, medium, low';
        end if;
        insert into public.player_values (league_id, team_id, player_id, value, updated_at, updated_by)
        values (v_league_id, p_team_id, p_player_id, v_clean, now(), auth.uid())
        on conflict (team_id, player_id) do update
            set value      = excluded.value,
                updated_at = now(),
                updated_by = auth.uid();
    end if;
end;
$$;

grant execute on function public.set_player_value(uuid, text, text) to authenticated;

-- Realtime so value changes propagate to open clients.
do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'player_values'
    ) then
        alter publication supabase_realtime drop table public.player_values;
    end if;
    alter publication supabase_realtime add table public.player_values;
end$$;
