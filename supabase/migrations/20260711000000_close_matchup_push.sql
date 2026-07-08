-- Close-matchup push: a Sunday late-afternoon nudge when a head-to-head is
-- within a few points, queued through the push_events outbox (drained by the
-- per-minute send_push cron). Pure SQL — lineups, live points, and league
-- schedules all live in Postgres, so no edge function is needed.

-- Live points for a team's active lineup this week: the frozen weekly lineup
-- when one exists, else the live starters. Preset scoring columns only —
-- custom-scoring leagues get the nearest preset, which is fine for a nudge.
create or replace function public.live_starter_points(
    p_team uuid, p_season int, p_week int, p_scoring text
) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
    t public.teams;
    lineup text[];
begin
    select * into t from public.teams where id = p_team;
    if not found then return 0; end if;
    if t.weekly_lineups ? (p_week::text) then
        lineup := array(select jsonb_array_elements_text(t.weekly_lineups->(p_week::text)));
    else
        lineup := t.starters;
    end if;
    return coalesce((
        select sum(case p_scoring
                       when 'standard' then ls.fantasy_points
                       when 'half'     then ls.fantasy_points_half_ppr
                       else                 ls.fantasy_points_ppr
                   end)
          from public.live_scores ls
         where ls.player_id = any(lineup)
           and ls.season = p_season
           and ls.week   = p_week
    ), 0);
end$$;

revoke execute on function public.live_starter_points(uuid, int, int, text) from public, anon, authenticated;

create or replace function public.notify_close_matchups(p_margin numeric default 10)
returns int
language plpgsql security definer set search_path = public as $$
declare
    v_season int;
    v_week   int;
    lg       record;
    m        jsonb;
    home_id  uuid;
    away_id  uuid;
    home_pts numeric;
    away_pts numeric;
    home_t   public.teams;
    away_t   public.teams;
    diff     numeric;
    sent     int := 0;
begin
    -- The active fantasy week = the NFL week of today's games. No games
    -- today (offseason, byes-only weirdness) → nothing to do.
    select season, week into v_season, v_week
      from public.nfl_schedules
     where kickoff::date = current_date
     order by kickoff
     limit 1;
    if v_season is null then return 0; end if;

    for lg in
        select l.id, l.scoring, l.schedule
          from public.leagues l
         where l.season = v_season
           and coalesce(l.is_test, false) = false
           and coalesce(l.season_completed, false) = false
    loop
        for m in
            select jsonb_array_elements(wk->'matchups')
              from jsonb_array_elements(lg.schedule) wk
             where (wk->>'week')::int = v_week
        loop
            begin
                home_id := (m->>0)::uuid;
                away_id := (m->>1)::uuid;
            exception when others then
                continue;  -- bye sentinel / malformed pair
            end;

            select * into home_t from public.teams where id = home_id;
            if not found then continue; end if;
            select * into away_t from public.teams where id = away_id;
            if not found then continue; end if;
            -- Both sides need a human to notify, and someone must have
            -- actually scored (empty lineups / pre-kickoff → skip).
            if home_t.owner_id is null or away_t.owner_id is null then continue; end if;

            home_pts := public.live_starter_points(home_id, v_season, v_week, lg.scoring);
            away_pts := public.live_starter_points(away_id, v_season, v_week, lg.scoring);
            if home_pts + away_pts <= 0 then continue; end if;

            diff := abs(home_pts - away_pts);
            if diff > p_margin then continue; end if;

            perform public.queue_push(
                home_t.owner_id,
                'Close matchup',
                case when home_pts >= away_pts
                     then 'You lead ' || away_t.name || ' ' || round(home_pts, 1) || '–' || round(away_pts, 1) || ' — tight one down the stretch.'
                     else 'You trail ' || away_t.name || ' ' || round(away_pts, 1) || '–' || round(home_pts, 1) || ' — still anyone''s game.'
                end,
                'tarsafantasy://league/' || lg.id
            );
            perform public.queue_push(
                away_t.owner_id,
                'Close matchup',
                case when away_pts >= home_pts
                     then 'You lead ' || home_t.name || ' ' || round(away_pts, 1) || '–' || round(home_pts, 1) || ' — tight one down the stretch.'
                     else 'You trail ' || home_t.name || ' ' || round(home_pts, 1) || '–' || round(away_pts, 1) || ' — still anyone''s game.'
                end,
                'tarsafantasy://league/' || lg.id
            );
            sent := sent + 2;
        end loop;
    end loop;
    return sent;
end$$;

revoke execute on function public.notify_close_matchups(numeric) from public, anon, authenticated;

-- Sunday 21:30 UTC = 5:30pm EDT / 4:30pm EST — late-afternoon window with
-- games in progress. Once a week, so no dedupe bookkeeping is needed.
select cron.unschedule('close_matchup_sunday')
    where exists (select 1 from cron.job where jobname = 'close_matchup_sunday');
select cron.schedule(
    'close_matchup_sunday',
    '30 21 * * 0',
    $$select public.notify_close_matchups()$$
);
