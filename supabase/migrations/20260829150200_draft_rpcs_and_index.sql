-- Applied to prod 2026-08-29. Idempotent.
-- (Index already built CONCURRENTLY on prod 2026-08-29; plain IF NOT EXISTS here because
-- `supabase db push` runs each migration inside a transaction.)
-- One-call replacements for the paginated full-table pulls in draft_tick and
-- sync_espn_live (each was 5-40 PostgREST round trips per run, with a disk
-- sort per page on player_games). All return jsonb so PostgREST's max-rows
-- limit does not truncate them. service_role only.
create index if not exists player_games_season_player_week_idx
  on public.player_games (season, player_id, week);

create or replace function public.draft_season_totals(p_season int)
returns jsonb language sql stable security definer set search_path = public as $f$
  select coalesce(jsonb_object_agg(player_id, ppr), '{}'::jsonb)
    from (select player_id, sum(fantasy_points_ppr) as ppr
            from public.player_games where season = p_season group by player_id) t;
$f$;

create or replace function public.draft_pool()
returns jsonb language sql stable security definer set search_path = public as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'position', "position", 'years_exp', years_exp, 'draft_year', draft_year) order by id), '[]'::jsonb)
    from public.players_cache;
$f$;

create or replace function public.espn_id_map()
returns jsonb language sql stable security definer set search_path = public as $f$
  select coalesce(jsonb_object_agg(espn_id, id), '{}'::jsonb)
    from public.players_cache where espn_id is not null;
$f$;

revoke all on function public.draft_season_totals(int) from public, anon, authenticated;
revoke all on function public.draft_pool() from public, anon, authenticated;
revoke all on function public.espn_id_map() from public, anon, authenticated;
