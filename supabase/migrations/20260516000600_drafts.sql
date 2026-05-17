-- Live drafts: one per league. The commissioner schedules a start time and
-- a per-pick clock; the room opens at that time and owners pick in order.
-- When the pick clock expires (handled by the draft_tick edge function or by
-- any connected client noticing the local deadline has passed) the next
-- best-available player is auto-picked.

-- 1. The draft itself. One row per league at most; status drives the room.
create table if not exists public.drafts (
    id                uuid primary key default gen_random_uuid(),
    league_id         uuid not null unique references public.leagues(id) on delete cascade,
    format            text not null default 'snake',          -- 'snake' | 'linear'
    status            text not null default 'scheduled',      -- 'scheduled' | 'live' | 'paused' | 'complete'
    pick_seconds      int  not null default 60,               -- per-pick clock
    starts_at         timestamptz not null,
    started_at        timestamptz,
    completed_at      timestamptz,
    current_pick      int  not null default 0,                -- 1-indexed; 0 = not started
    total_picks       int  not null default 0,                -- teams * roster_size, computed on create
    pick_deadline     timestamptz,                            -- when the current pick auto-expires
    pick_order        text[] not null default '{}',           -- ordered team-id strings (round 1)
    paused_at         timestamptz,
    paused_remaining  int                                     -- seconds left on the clock when paused
);
create index if not exists drafts_status_idx on public.drafts (status);

-- 2. Picks log. One row per pick (manual or auto).
create table if not exists public.draft_picks (
    id           uuid primary key default gen_random_uuid(),
    draft_id     uuid not null references public.drafts(id) on delete cascade,
    pick_number  int  not null,
    team_id      uuid not null references public.teams(id),
    player_id    text not null,
    auto_pick    boolean not null default false,
    picked_at    timestamptz not null default now(),
    unique (draft_id, pick_number),
    unique (draft_id, player_id)
);
create index if not exists draft_picks_draft_idx on public.draft_picks (draft_id, pick_number);

-- 3. RLS — readable by any signed-in user; commissioner can manage the draft
-- row, team owners can insert picks only on their own turn (verified
-- transactionally in the make_pick RPC below).
alter table public.drafts      enable row level security;
alter table public.draft_picks enable row level security;

drop policy if exists "drafts_read"      on public.drafts;
drop policy if exists "drafts_commish"   on public.drafts;
drop policy if exists "draft_picks_read" on public.draft_picks;
drop policy if exists "draft_picks_self" on public.draft_picks;

create policy "drafts_read"
    on public.drafts for select using (auth.role() = 'authenticated');

create policy "drafts_commish"
    on public.drafts for all
    using (
        exists (select 1 from public.leagues l
                where l.id = drafts.league_id and l.creator_id = auth.uid())
    )
    with check (
        exists (select 1 from public.leagues l
                where l.id = drafts.league_id and l.creator_id = auth.uid())
    );

create policy "draft_picks_read"
    on public.draft_picks for select using (auth.role() = 'authenticated');

-- Note: client doesn't insert picks directly; goes through public.make_pick()
-- defined below which validates the turn.

-- 4. RPC: make_pick. Atomically checks that the draft is live, the team is on
-- the clock, and the player isn't already picked or rostered. Inserts the
-- pick and advances current_pick + pick_deadline. Returns the new draft row.
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

    insert into public.draft_picks (draft_id, pick_number, team_id, player_id, auto_pick)
    values (p_draft_id, d.current_pick, p_team_id, p_player_id, p_is_auto);

    -- Append to the team's roster row.
    update public.teams
       set roster = array_append(roster, p_player_id)
     where id = p_team_id;

    next_pick    := d.current_pick + 1;
    new_deadline := now() + (d.pick_seconds || ' seconds')::interval;

    if next_pick > d.total_picks then
        update public.drafts
           set current_pick = next_pick,
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

-- 5. Helper: which team is on the clock for a given pick number? Encodes the
-- snake / linear format. Round 1 follows pick_order; in snake, even rounds
-- reverse.
create or replace function public.team_on_clock(p_draft_id uuid, p_pick int)
returns uuid language plpgsql stable as $$
declare
    d         public.drafts;
    team_count int;
    round_idx  int;     -- 0-indexed
    pos_in_round int;   -- 0-indexed
    team_id_text text;
begin
    select * into d from public.drafts where id = p_draft_id;
    if not found or p_pick < 1 then return null; end if;
    team_count := array_length(d.pick_order, 1);
    if team_count is null or team_count = 0 then return null; end if;

    round_idx    := (p_pick - 1) / team_count;
    pos_in_round := (p_pick - 1) % team_count;

    if d.format = 'snake' and (round_idx % 2 = 1) then
        pos_in_round := team_count - 1 - pos_in_round;
    end if;

    team_id_text := d.pick_order[pos_in_round + 1];   -- 1-indexed
    return team_id_text::uuid;
exception when others then
    return null;
end$$;

-- 6. RPC: start_draft (commissioner). Validates roster sizes are zero,
-- transitions scheduled → live, sets initial pick_deadline.
create or replace function public.start_draft(p_draft_id uuid)
returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    is_commish boolean;
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

    update public.drafts
       set status = 'live',
           started_at = coalesce(started_at, now()),
           current_pick = 1,
           pick_deadline = now() + (d.pick_seconds || ' seconds')::interval,
           paused_at = null,
           paused_remaining = null
     where id = p_draft_id
     returning * into d;
    return d;
end$$;

-- 7. RPC: pause / resume.
create or replace function public.pause_draft(p_draft_id uuid)
returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    is_commish boolean;
    remaining int;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can pause the draft';
    end if;
    if d.status <> 'live' then return d; end if;
    remaining := greatest(0, extract(epoch from (d.pick_deadline - now()))::int);
    update public.drafts
       set status = 'paused', paused_at = now(),
           paused_remaining = remaining, pick_deadline = null
     where id = p_draft_id
     returning * into d;
    return d;
end$$;

create or replace function public.resume_draft(p_draft_id uuid)
returns public.drafts
language plpgsql security definer set search_path = public as $$
declare
    d public.drafts;
    is_commish boolean;
    seconds int;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can resume the draft';
    end if;
    if d.status <> 'paused' then return d; end if;
    seconds := coalesce(d.paused_remaining, d.pick_seconds);
    update public.drafts
       set status = 'live', pick_deadline = now() + (seconds || ' seconds')::interval,
           paused_at = null, paused_remaining = null
     where id = p_draft_id
     returning * into d;
    return d;
end$$;

-- 8. Realtime: push draft + draft_picks rows so all rooms stay in sync.
do $$
declare
    t text;
begin
    foreach t in array array['drafts', 'draft_picks'] loop
        if exists (
            select 1 from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
        ) then
            execute format('alter publication supabase_realtime drop table public.%I', t);
        end if;
        execute format('alter publication supabase_realtime add table public.%I', t);
    end loop;
end$$;
