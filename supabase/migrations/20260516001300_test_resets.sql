-- Testing Environment: per-week resets.
--
-- Every mutation table grows a simulated_week column (NULL for non-test
-- leagues, auto-populated for test leagues via BEFORE INSERT triggers).
-- team_snapshots captures roster + starters at the entry of each simulated
-- week so reset_period can restore that point in time exactly.
--
-- Semantics:
--   reset_period(l) — restore rosters to the entry state of the league's
--                     CURRENT simulated_week and delete all mutations and
--                     snapshots at weeks >= current. Stays at the same week.
--   reset_all(l)    — restore week-0 entry state and delete everything
--                     beyond it. Sets simulated_week back to 0.
--
-- snapshot_teams(l, w) is idempotent — it inserts (or replaces) per-team
-- rows for the given week using the teams' current rosters.

-- 1. Tag columns
alter table public.transactions    add column if not exists simulated_week int;
alter table public.trades          add column if not exists simulated_week int;
alter table public.waiver_claims   add column if not exists simulated_week int;
alter table public.dropped_players add column if not exists simulated_week int;

-- 2. Trigger that auto-populates simulated_week for test leagues only.
create or replace function public.tag_with_simulated_week()
returns trigger language plpgsql as $$
declare
    lg public.leagues;
begin
    select * into lg from public.leagues where id = NEW.league_id;
    if coalesce(lg.is_test, false) then
        NEW.simulated_week := coalesce(lg.simulated_week, 0);
    end if;
    return NEW;
end$$;

drop trigger if exists transactions_tag_simulated_week    on public.transactions;
drop trigger if exists trades_tag_simulated_week          on public.trades;
drop trigger if exists waiver_claims_tag_simulated_week   on public.waiver_claims;
drop trigger if exists dropped_players_tag_simulated_week on public.dropped_players;

create trigger transactions_tag_simulated_week
    before insert on public.transactions
    for each row execute function public.tag_with_simulated_week();

create trigger trades_tag_simulated_week
    before insert on public.trades
    for each row execute function public.tag_with_simulated_week();

create trigger waiver_claims_tag_simulated_week
    before insert on public.waiver_claims
    for each row execute function public.tag_with_simulated_week();

create trigger dropped_players_tag_simulated_week
    before insert on public.dropped_players
    for each row execute function public.tag_with_simulated_week();

-- 3. Snapshot table
create table if not exists public.team_snapshots (
    league_id       uuid not null references public.leagues(id) on delete cascade,
    team_id         uuid not null references public.teams(id)   on delete cascade,
    simulated_week  int  not null,
    roster          text[] not null default '{}',
    starters        text[] not null default '{}',
    captured_at     timestamptz not null default now(),
    primary key (team_id, simulated_week)
);
create index if not exists team_snapshots_league_idx on public.team_snapshots (league_id, simulated_week);

alter table public.team_snapshots enable row level security;
drop policy if exists "team_snapshots_read"  on public.team_snapshots;
drop policy if exists "team_snapshots_write" on public.team_snapshots;

create policy "team_snapshots_read"
    on public.team_snapshots for select
    using (auth.role() = 'authenticated');

-- Commissioner can write snapshots (which is what the test-env owner is).
create policy "team_snapshots_write"
    on public.team_snapshots for all
    using (
        exists (
            select 1 from public.leagues l
            where l.id = team_snapshots.league_id and l.creator_id = auth.uid()
        )
    )
    with check (
        exists (
            select 1 from public.leagues l
            where l.id = team_snapshots.league_id and l.creator_id = auth.uid()
        )
    );

-- 4. RPC: snapshot_teams
-- Captures every team's current roster + starters at the given week.
-- ON CONFLICT do nothing — first snapshot wins, so re-capturing because
-- bot activity ran is a no-op (we want the pristine entry state).
create or replace function public.snapshot_teams(p_league_id uuid, p_week int)
returns void
language plpgsql security definer set search_path = public as $$
declare
    lg public.leagues;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found or not coalesce(lg.is_test, false) then return; end if;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the league creator can snapshot';
    end if;

    insert into public.team_snapshots (league_id, team_id, simulated_week, roster, starters)
    select t.league_id, t.id, p_week, t.roster, t.starters
      from public.teams t
     where t.league_id = p_league_id
    on conflict (team_id, simulated_week) do nothing;
end$$;

-- 5. RPC: reset_period — wipes mutations in the current week and any later
-- weeks, restores rosters from the snapshot at the current week.
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

    -- Wipe mutations at this week and any "future" weeks (forward jumps
    -- might have happened, but reset is the destructive cliff).
    delete from public.transactions    where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.trades          where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.waiver_claims   where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.dropped_players where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;

    -- Restore rosters from the current-week snapshot if we have one.
    update public.teams t
       set roster = s.roster, starters = s.starters
      from public.team_snapshots s
     where s.team_id = t.id
       and s.simulated_week = current_week
       and t.league_id = p_league_id;

    -- Drop snapshots beyond the current week; they're no longer reachable.
    delete from public.team_snapshots
     where league_id = p_league_id and simulated_week > current_week;

    return lg;
end$$;

-- 6. RPC: reset_all — full wipe back to preseason.
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

    -- Restore from week 0 if a snapshot exists.
    update public.teams t
       set roster = s.roster, starters = s.starters
      from public.team_snapshots s
     where s.team_id = t.id
       and s.simulated_week = 0
       and t.league_id = p_league_id;

    delete from public.team_snapshots
     where league_id = p_league_id and simulated_week > 0;

    update public.leagues set simulated_week = 0 where id = p_league_id;
    select * into lg from public.leagues where id = p_league_id;
    return lg;
end$$;
