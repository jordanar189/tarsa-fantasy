-- Team customization round 2: per-team abbreviation, plus owner-assigned
-- player nicknames.
--
-- Abbreviation is a plain additive column on teams (NULL = derive/none).
--
-- Nicknames live in their own table so they can carry history. A nickname is
-- "active" while cleared_at IS NULL; it is archived (cleared_at set) the moment
-- the player leaves the team's roster — via ANY drop path (manual drop, waiver
-- process, trade, reset) — because every path mutates teams.roster and a single
-- trigger reconciles against it. Re-adding a previously-dropped player does NOT
-- restore the old nickname (it stays archived), which matches the "reset on
-- drop, keep history" requirement.

-- 1. Team abbreviation.
alter table public.teams
    add column if not exists abbreviation text;

-- 2. Player nicknames (one active row per team+player, history retained).
create table if not exists public.player_nicknames (
    id          uuid primary key default gen_random_uuid(),
    league_id   uuid not null references public.leagues(id) on delete cascade,
    team_id     uuid not null references public.teams(id)   on delete cascade,
    player_id   text not null,
    nickname    text not null,
    created_at  timestamptz not null default now(),
    cleared_at  timestamptz,                 -- NULL = active; set when archived
    created_by  uuid default auth.uid()
);

-- At most one active nickname per (team, player).
create unique index if not exists player_nicknames_active_uq
    on public.player_nicknames (team_id, player_id) where cleared_at is null;
create index if not exists player_nicknames_player_idx
    on public.player_nicknames (player_id);
create index if not exists player_nicknames_league_idx
    on public.player_nicknames (league_id) where cleared_at is null;

-- 3. RLS. Nicknames are free-text, league-scoped UGC, so reads are limited to
-- members of the league (mirrors the league-chat model); writes go exclusively
-- through the validated RPC.
alter table public.player_nicknames enable row level security;

drop policy if exists "player_nicknames_read" on public.player_nicknames;
create policy "player_nicknames_read" on public.player_nicknames
    for select using (public.is_league_member(league_id));

-- 4. Archive active nicknames whose player has left the roster. Fires on every
-- teams.roster change, so it catches drops/trades/waivers/resets uniformly.
create or replace function public.clear_dropped_nicknames()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if NEW.roster is distinct from OLD.roster then
        update public.player_nicknames
           set cleared_at = now()
         where team_id = NEW.id
           and cleared_at is null
           and not (player_id = any(NEW.roster));
    end if;
    return NEW;
end;
$$;

drop trigger if exists teams_clear_nicknames on public.teams;
create trigger teams_clear_nicknames
    after update on public.teams
    for each row
    execute function public.clear_dropped_nicknames();

-- 5. Set / update / clear a nickname for a player the caller's team owns.
-- Empty/blank nickname archives the active one. While the player stays on the
-- roster the active row is updated in place (no history churn on edits); the
-- drop trigger is what freezes a nickname into history.
create or replace function public.set_player_nickname(
    p_team_id   uuid,
    p_player_id text,
    p_nickname  text
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
        raise exception 'not authorized to nickname players on this team';
    end if;

    select exists (
        select 1 from public.teams t
         where t.id = p_team_id and p_player_id = any(t.roster)
    ) into v_on_roster;
    if not v_on_roster then
        raise exception 'player is not on this team''s roster';
    end if;

    v_clean := nullif(btrim(coalesce(p_nickname, '')), '');

    if v_clean is null then
        update public.player_nicknames
           set cleared_at = now()
         where team_id = p_team_id and player_id = p_player_id and cleared_at is null;
    else
        update public.player_nicknames
           set nickname = v_clean
         where team_id = p_team_id and player_id = p_player_id and cleared_at is null;
        if not found then
            insert into public.player_nicknames (league_id, team_id, player_id, nickname)
            values (v_league_id, p_team_id, p_player_id, v_clean);
        end if;
    end if;
end;
$$;

grant execute on function public.set_player_nickname(uuid, text, text) to authenticated;

-- 6. Nickname history for one player (active + archived), newest first, with
-- the team and league that gave each. Read-side only, and limited to leagues
-- the caller belongs to (SECURITY DEFINER bypasses RLS, so membership is
-- enforced explicitly in the WHERE clause).
create or replace function public.player_nickname_history(p_player_id text)
returns table (
    nickname    text,
    team_name   text,
    league_name text,
    created_at  timestamptz,
    cleared_at  timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    select pn.nickname, t.name, l.name, pn.created_at, pn.cleared_at
      from public.player_nicknames pn
      join public.teams   t on t.id = pn.team_id
      join public.leagues l on l.id = pn.league_id
     where pn.player_id = p_player_id
       -- Scope to the caller's leagues so cross-league nickname/team/league
       -- text isn't exposed outside league membership.
       and public.is_league_member(pn.league_id)
     order by pn.created_at desc;
$$;

grant execute on function public.player_nickname_history(text) to authenticated;

-- 7. Realtime so nickname changes propagate to open clients.
do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'player_nicknames'
    ) then
        alter publication supabase_realtime drop table public.player_nicknames;
    end if;
    alter publication supabase_realtime add table public.player_nicknames;
end$$;
