-- Fix: final-week trades could never execute.
--
-- attempt_execute_trade treated a player as "locked" when they had a
-- player_games row for max(week) of the season, and deferred until a LATER
-- week's stats bumped max(week). In the season's final week max(week) never
-- advances, so any trade touching a player who played that week sat in
-- pending_execution forever. The heuristic also locked players for a full
-- week after their game ended (until the next week's data landed).
--
-- New rule, derived from the real schedule: a player is locked iff their NFL
-- team's game is IN PROGRESS right now — kicked off (kickoff <= now()) and
-- not final. Once the game finals the player unlocks and the hourly retry
-- executes the trade, including in week 18.
--
-- Everything else (roster swap, status transitions, transaction logging) is
-- unchanged from 20260516000800_trades.sql.

create or replace function public.attempt_execute_trade(p_trade_id uuid)
returns public.trades
language plpgsql security definer set search_path = public as $$
declare
    t public.trades;
    lg public.leagues;
    proposer public.teams;
    recipient public.teams;
    locked_count int;
    new_proposer_roster text[];
    new_recipient_roster text[];
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then return null; end if;
    if t.status <> 'pending_execution' then return t; end if;

    select * into lg        from public.leagues where id = t.league_id;
    select * into proposer  from public.teams   where id = t.proposer_team_id;
    select * into recipient from public.teams   where id = t.recipient_team_id;

    -- Locked = the player's NFL team has a game in progress right now.
    -- (status is authoritative when the live sync has run; the kickoff
    -- comparison covers the window before it flips to in_progress.)
    select count(*) into locked_count
      from public.players_cache pc
      join public.nfl_schedules g
        on g.season = lg.season
       and (g.home_team = pc.team or g.away_team = pc.team)
     where pc.id = any (t.proposer_player_ids || t.recipient_player_ids)
       and g.status <> 'final'
       and (g.status = 'in_progress'
            or (g.kickoff is not null and g.kickoff <= now()));

    if locked_count > 0 then
        -- Stay in pending_execution; the hourly cron retries and succeeds
        -- once the in-progress games go final.
        return t;
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

    update public.teams set roster = new_proposer_roster  where id = proposer.id;
    update public.teams set roster = new_recipient_roster where id = recipient.id;

    update public.trades
       set status = 'executed', executed_at = now(),
           resolved_at = coalesce(resolved_at, now())
     where id = p_trade_id
     returning * into t;

    -- Log a transaction row per side so the Activity feed reflects both
    -- ends of the swap with the player IDs that moved.
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
