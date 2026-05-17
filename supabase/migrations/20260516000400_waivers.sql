-- Waivers, free-agent claims, and transaction history.
--
-- Standard waiver model: when a player is dropped, they enter a waiver
-- period (default 24h or until the next configured "process" tick). Other
-- teams can submit claims with a chosen drop player; at process time, the
-- background worker resolves claims in waiver-priority order (lowest number
-- wins first). Players not on waivers are free agents — added instantly.
--
-- Commissioner approval (optional, per-league) keeps each add/drop in a
-- pending_approval state until the league creator approves or rejects it.

-- 1. Extend leagues with waiver settings.
alter table public.leagues
    add column if not exists waiver_process_day   smallint not null default 3,    -- 0=Sun ... 6=Sat (3 = Wed)
    add column if not exists waiver_process_hour  smallint not null default 8,    -- UTC hour
    add column if not exists waiver_period_hours  smallint not null default 24,
    add column if not exists commissioner_approval boolean not null default false,
    add column if not exists waiver_priority      text[]   not null default '{}', -- ordered team-id strings; first = highest priority
    add column if not exists last_waivers_run_at  timestamptz;

-- 2. Pending waiver claims.
create table if not exists public.waiver_claims (
    id              uuid primary key default gen_random_uuid(),
    league_id       uuid not null references public.leagues(id) on delete cascade,
    team_id         uuid not null references public.teams(id)   on delete cascade,
    add_player_id   text not null,
    drop_player_id  text,
    team_priority   int  not null default 1,     -- ordering within this team's stack of claims
    status          text not null default 'pending', -- pending | processed | failed | cancelled
    failure_reason  text,
    created_at      timestamptz not null default now(),
    processed_at    timestamptz
);
create index if not exists waiver_claims_league_status_idx on public.waiver_claims (league_id, status);
create index if not exists waiver_claims_team_idx          on public.waiver_claims (team_id);

-- 3. Transaction log + commissioner-approval pipeline.
create table if not exists public.transactions (
    id              uuid primary key default gen_random_uuid(),
    league_id       uuid not null references public.leagues(id) on delete cascade,
    team_id         uuid not null references public.teams(id)   on delete cascade,
    kind            text not null,                       -- add | drop | add_drop | waiver_claim | trade
    add_player_id   text,
    drop_player_id  text,
    status          text not null default 'completed',   -- completed | pending_approval | rejected | failed
    note            text,
    created_at      timestamptz not null default now(),
    resolved_at     timestamptz,
    resolved_by     uuid                                  -- profile id of the commissioner who approved/rejected
);
create index if not exists transactions_league_created_idx on public.transactions (league_id, created_at desc);
create index if not exists transactions_league_status_idx  on public.transactions (league_id, status);

-- 4. Track when a player was dropped from a league (start of waiver period).
-- Read by the client to know if a player is currently on waivers and by the
-- process worker to know which claims are valid.
create table if not exists public.dropped_players (
    league_id      uuid not null references public.leagues(id) on delete cascade,
    player_id      text not null,
    dropped_at     timestamptz not null default now(),
    waiver_until   timestamptz not null,
    primary key (league_id, player_id)
);
create index if not exists dropped_players_until_idx on public.dropped_players (waiver_until);

-- 5. RLS — readable by any signed-in user (we're a small app, league reads
-- aren't sensitive). Writes are restricted to either the team owner or the
-- league creator (commissioner).
alter table public.waiver_claims    enable row level security;
alter table public.transactions     enable row level security;
alter table public.dropped_players  enable row level security;

drop policy if exists "waiver_claims_read"    on public.waiver_claims;
drop policy if exists "waiver_claims_write"   on public.waiver_claims;
drop policy if exists "transactions_read"     on public.transactions;
drop policy if exists "transactions_insert"   on public.transactions;
drop policy if exists "transactions_update"   on public.transactions;
drop policy if exists "dropped_players_read"  on public.dropped_players;
drop policy if exists "dropped_players_write" on public.dropped_players;

create policy "waiver_claims_read"    on public.waiver_claims    for select using (auth.role() = 'authenticated');
create policy "transactions_read"     on public.transactions     for select using (auth.role() = 'authenticated');
create policy "dropped_players_read"  on public.dropped_players  for select using (auth.role() = 'authenticated');

-- Team owner can manage their own claims.
create policy "waiver_claims_write" on public.waiver_claims
    for all using (
        exists (select 1 from public.teams t
                where t.id = waiver_claims.team_id
                  and t.owner_id = auth.uid())
    ) with check (
        exists (select 1 from public.teams t
                where t.id = waiver_claims.team_id
                  and t.owner_id = auth.uid())
    );

-- Team owner can insert their own transactions (add/drop) and the commissioner
-- can update status (approve/reject).
create policy "transactions_insert" on public.transactions
    for insert with check (
        exists (select 1 from public.teams t
                where t.id = transactions.team_id
                  and t.owner_id = auth.uid())
    );
create policy "transactions_update" on public.transactions
    for update using (
        exists (select 1 from public.leagues l
                where l.id = transactions.league_id
                  and l.creator_id = auth.uid())
    );

-- Anyone who can touch a team in the league may write dropped_players rows
-- (a drop happens as part of an add/drop). Restrict by league membership.
create policy "dropped_players_write" on public.dropped_players
    for all using (
        exists (select 1 from public.teams t
                where t.league_id = dropped_players.league_id
                  and t.owner_id = auth.uid())
        or
        exists (select 1 from public.leagues l
                where l.id = dropped_players.league_id
                  and l.creator_id = auth.uid())
    ) with check (
        exists (select 1 from public.teams t
                where t.league_id = dropped_players.league_id
                  and t.owner_id = auth.uid())
        or
        exists (select 1 from public.leagues l
                where l.id = dropped_players.league_id
                  and l.creator_id = auth.uid())
    );

-- 6. Realtime: push waiver_claims + transactions + dropped_players so clients
-- update without polling.
do $$
declare
    t text;
begin
    foreach t in array array['waiver_claims', 'transactions', 'dropped_players'] loop
        if exists (
            select 1 from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
        ) then
            execute format('alter publication supabase_realtime drop table public.%I', t);
        end if;
        execute format('alter publication supabase_realtime add table public.%I', t);
    end loop;
end$$;

-- 7. Backfill waiver_priority for any pre-existing leagues: reverse of team
-- sort_index (last team picks first, fantasy-football tradition).
update public.leagues l
   set waiver_priority = sub.ids
  from (
      select league_id, array_agg(id::text order by sort_index desc) as ids
        from public.teams
       group by league_id
  ) sub
 where sub.league_id = l.id
   and (l.waiver_priority is null or array_length(l.waiver_priority, 1) is null);

-- 8. Process-waivers cron (hourly; the worker no-ops for leagues that aren't
-- yet due). Function added in 20260516000500_process_waivers_cron.sql so this
-- migration stays runnable even if the edge function isn't deployed yet.
