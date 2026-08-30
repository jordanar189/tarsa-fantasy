-- Applied to prod 2026-08-29. Idempotent (re-running yields identical policies).
-- Wraps every direct auth.uid()/auth.role() call in RLS policies as
-- (select auth.uid()) so Postgres evaluates it once per query (InitPlan)
-- instead of once per row. Semantics unchanged. This was the Supabase
-- performance advisor's 65 `auth_rls_initplan` warnings.
-- Generated from pg_policies with:
--   select format('alter policy %I on %I.%I%s%s;', policyname, schemaname, tablename,
--     case when qual is not null then ' using (' || regexp_replace(qual, '(?<![sS][eE][lL][eE][cC][tT]\s)auth\.(uid|role|jwt|email)\(\)', '(select auth.\1())', 'g') || ')' else '' end,
--     case when with_check is not null then ' with check (' || regexp_replace(with_check, '(?<![sS][eE][lL][eE][cC][tT]\s)auth\.(uid|role|jwt|email)\(\)', '(select auth.\1())', 'g') || ')' else '' end)
--   from pg_policies where schemaname = 'public' and (qual ~ '(?<![sS][eE][lL][eE][cC][tT]\s)auth\.(uid|role|jwt|email)\(\)' or with_check ~ '(?<![sS][eE][lL][eE][cC][tT]\s)auth\.(uid|role|jwt|email)\(\)');
alter policy adp_read on public.adp using (((select auth.role()) = 'authenticated'::text));
alter policy app_settings_read on public.app_settings using (((select auth.role()) = 'authenticated'::text));
alter policy app_settings_write on public.app_settings using ((EXISTS (SELECT 1 FROM profiles p WHERE ((p.id = (select auth.uid())) AND (p.is_admin = true))))) with check ((EXISTS (SELECT 1 FROM profiles p WHERE ((p.id = (select auth.uid())) AND (p.is_admin = true)))));
alter policy depth_charts_read on public.depth_charts using (((select auth.role()) = 'authenticated'::text));
alter policy device_tokens_select on public.device_tokens using ((user_id = (select auth.uid())));
alter policy dm_messages_delete on public.dm_messages using ((sender_id = (select auth.uid())));
alter policy dm_messages_insert on public.dm_messages with check (((sender_id = (select auth.uid())) AND is_dm_participant(thread_id)));
alter policy dm_threads_insert on public.dm_threads with check ((((select auth.uid()) = user_a) OR ((select auth.uid()) = user_b)));
alter policy dm_threads_read on public.dm_threads using ((((select auth.uid()) = user_a) OR ((select auth.uid()) = user_b)));
alter policy draft_queues_read on public.draft_queues using ((EXISTS (SELECT 1 FROM teams t WHERE ((t.id = draft_queues.team_id) AND (t.owner_id = (select auth.uid()))))));
alter policy drafts_commish on public.drafts using ((EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = drafts.league_id) AND (l.creator_id = (select auth.uid())))))) with check ((EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = drafts.league_id) AND (l.creator_id = (select auth.uid()))))));
alter policy dropped_players_write on public.dropped_players using (((EXISTS (SELECT 1 FROM teams t WHERE ((t.league_id = dropped_players.league_id) AND (t.owner_id = (select auth.uid()))))) OR (EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = dropped_players.league_id) AND (l.creator_id = (select auth.uid()))))))) with check (((EXISTS (SELECT 1 FROM teams t WHERE ((t.league_id = dropped_players.league_id) AND (t.owner_id = (select auth.uid()))))) OR (EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = dropped_players.league_id) AND (l.creator_id = (select auth.uid())))))));
alter policy feedback_delete on public.feedback using (((user_id = (select auth.uid())) OR is_app_admin()));
alter policy feedback_insert on public.feedback with check (((user_id = (select auth.uid())) AND (EXISTS (SELECT 1 FROM profiles p WHERE ((p.id = (select auth.uid())) AND ((p.is_tester = true) OR (p.is_admin = true)))))));
alter policy feedback_read on public.feedback using (((user_id = (select auth.uid())) OR is_app_admin()));
alter policy feedback_comments_delete on public.feedback_comments using (((user_id = (select auth.uid())) OR is_app_admin()));
alter policy feedback_comments_insert on public.feedback_comments with check (((user_id = (select auth.uid())) AND can_access_feedback(feedback_id)));
alter policy friendships_delete on public.friendships using ((((select auth.uid()) = user_a) OR ((select auth.uid()) = user_b)));
alter policy friendships_insert on public.friendships with check (((requested_by = (select auth.uid())) AND (((select auth.uid()) = user_a) OR ((select auth.uid()) = user_b)) AND (status = 'pending'::text)));
alter policy friendships_read on public.friendships using ((((select auth.uid()) = user_a) OR ((select auth.uid()) = user_b)));
alter policy friendships_update on public.friendships using (((((select auth.uid()) = user_a) OR ((select auth.uid()) = user_b)) AND ((select auth.uid()) <> requested_by) AND (status = 'pending'::text))) with check ((status = 'accepted'::text));
alter policy inactives_read on public.inactives using (((select auth.role()) = 'authenticated'::text));
alter policy injuries_read on public.injuries using (((select auth.role()) = 'authenticated'::text));
alter policy injury_history_read on public.injury_history using (((select auth.role()) = 'authenticated'::text));
alter policy league_matchups_read on public.league_matchups using (((select auth.role()) = 'authenticated'::text));
alter policy league_reactions_delete on public.league_message_reactions using ((user_id = (select auth.uid())));
alter policy league_reactions_insert on public.league_message_reactions with check (((user_id = (select auth.uid())) AND (EXISTS (SELECT 1 FROM league_messages m WHERE ((m.id = league_message_reactions.message_id) AND is_league_member(m.league_id))))));
alter policy league_messages_delete on public.league_messages using (((user_id = (select auth.uid())) OR (EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = league_messages.league_id) AND (l.creator_id = (select auth.uid())))))));
alter policy league_messages_insert on public.league_messages with check (((user_id = (select auth.uid())) AND is_league_member(league_id)));
alter policy league_seasons_read on public.league_seasons using (((select auth.role()) = 'authenticated'::text));
alter policy leagues_delete_creator on public.leagues using ((creator_id = (select auth.uid())));
alter policy leagues_insert_creator on public.leagues with check ((creator_id = (select auth.uid())));
alter policy leagues_read_authed on public.leagues using (((select auth.role()) = 'authenticated'::text));
alter policy leagues_update_creator on public.leagues using ((creator_id = (select auth.uid())));
alter policy live_scores_read on public.live_scores using (((select auth.role()) = 'authenticated'::text));
alter policy message_responses_delete on public.message_responses using ((user_id = (select auth.uid())));
alter policy message_responses_insert on public.message_responses with check (((user_id = (select auth.uid())) AND (EXISTS (SELECT 1 FROM league_messages m WHERE ((m.id = message_responses.message_id) AND is_league_member(m.league_id))))));
alter policy message_responses_update on public.message_responses using ((user_id = (select auth.uid()))) with check ((user_id = (select auth.uid())));
alter policy most_started_read on public.most_started using (((select auth.role()) = 'authenticated'::text));
alter policy most_started_history_read on public.most_started_history using (((select auth.role()) = 'authenticated'::text));
alter policy nfl_schedules_read on public.nfl_schedules using (((select auth.role()) = 'authenticated'::text));
alter policy team_ranks_read on public.nfl_team_ranks using (((select auth.role()) = 'authenticated'::text));
alter policy nfl_team_ranks_history_read on public.nfl_team_ranks_history using (((select auth.role()) = 'authenticated'::text));
alter policy nfl_teams_read on public.nfl_teams using (((select auth.role()) = 'authenticated'::text));
alter policy player_games_read on public.player_games using (((select auth.role()) = 'authenticated'::text));
alter policy player_news_read on public.player_news using (((select auth.role()) = 'authenticated'::text));
alter policy players_cache_read on public.players_cache using (((select auth.role()) = 'authenticated'::text));
alter policy plays_read on public.plays using (((select auth.role()) = 'authenticated'::text));
alter policy profiles_insert_self on public.profiles with check (((select auth.uid()) = id));
alter policy profiles_update_self on public.profiles using (((select auth.uid()) = id));
alter policy profiles_update_theme_self on public.profiles using ((id = (select auth.uid()))) with check ((id = (select auth.uid())));
alter policy seasons_read on public.seasons using (((select auth.role()) = 'authenticated'::text));
alter policy snap_counts_read on public.snap_counts using (((select auth.role()) = 'authenticated'::text));
alter policy team_snapshots_read on public.team_snapshots using (((select auth.role()) = 'authenticated'::text));
alter policy team_snapshots_write on public.team_snapshots using ((EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = team_snapshots.league_id) AND (l.creator_id = (select auth.uid())))))) with check ((EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = team_snapshots.league_id) AND (l.creator_id = (select auth.uid()))))));
alter policy teams_commish_update on public.teams using ((EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = teams.league_id) AND (l.creator_id = (select auth.uid())))))) with check ((EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = teams.league_id) AND (l.creator_id = (select auth.uid()))))));
alter policy teams_insert_creator on public.teams with check ((EXISTS (SELECT 1 FROM leagues WHERE ((leagues.id = teams.league_id) AND (leagues.creator_id = (select auth.uid()))))));
alter policy teams_read_authed on public.teams using (((select auth.role()) = 'authenticated'::text));
alter policy teams_update_owner on public.teams using (((owner_id = (select auth.uid())) OR ((owner_id IS NULL) AND ((select auth.role()) = 'authenticated'::text))));
alter policy transactions_insert on public.transactions with check ((EXISTS (SELECT 1 FROM teams t WHERE ((t.id = transactions.team_id) AND (t.owner_id = (select auth.uid()))))));
alter policy transactions_update on public.transactions using ((EXISTS (SELECT 1 FROM leagues l WHERE ((l.id = transactions.league_id) AND (l.creator_id = (select auth.uid()))))));
alter policy trending_history_read on public.trending_history using (((select auth.role()) = 'authenticated'::text));
alter policy trending_read on public.trending_players using (((select auth.role()) = 'authenticated'::text));
alter policy waiver_claims_read on public.waiver_claims using ((is_league_member(league_id) AND ((status <> 'pending'::text) OR (EXISTS (SELECT 1 FROM teams t WHERE ((t.id = waiver_claims.team_id) AND (t.owner_id = (select auth.uid()))))))));
alter policy waiver_claims_write on public.waiver_claims using ((EXISTS (SELECT 1 FROM teams t WHERE ((t.id = waiver_claims.team_id) AND (t.owner_id = (select auth.uid())))))) with check ((EXISTS (SELECT 1 FROM teams t WHERE ((t.id = waiver_claims.team_id) AND (t.owner_id = (select auth.uid()))))));
