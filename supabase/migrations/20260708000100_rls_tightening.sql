-- RLS tightening: league-scoped reads for transactional data.
--
-- The early tables shipped with `auth.role() = 'authenticated'` read
-- policies, so any signed-in user could read every league's trades, votes,
-- transaction history, waiver activity, and draft state — and, worst,
-- any team's private DRAFT QUEUE (pre-draft strategy). Later tables already
-- use is_league_member(); this brings the older ones in line.
--
-- Deliberately left league-readable by any signed-in user:
--   * league_seasons / league_matchups (history archives) — history rows
--     belong to ANCESTOR league ids, and a member who joined this season
--     isn't a member of prior seasons' leagues; scoping them would blank
--     the History tab for newer members. Final standings are low-risk.
--   * NFL reference data (injuries, ADP, schedules, trending) — global.

-- Draft queues: strictly the owning team's owner. Not even the commissioner
-- (it's private strategy, and commish tools never read other teams' queues).
drop policy if exists "draft_queues_read" on public.draft_queues;
create policy "draft_queues_read"
    on public.draft_queues for select using (
        exists (select 1 from public.teams t
                where t.id = draft_queues.team_id
                  and t.owner_id = auth.uid())
    );

drop policy if exists "trades_read" on public.trades;
create policy "trades_read" on public.trades
    for select using (public.is_league_member(league_id));

drop policy if exists "trade_votes_read" on public.trade_votes;
create policy "trade_votes_read" on public.trade_votes
    for select using (
        exists (select 1 from public.trades t
                where t.id = trade_votes.trade_id
                  and public.is_league_member(t.league_id))
    );

drop policy if exists "transactions_read" on public.transactions;
create policy "transactions_read" on public.transactions
    for select using (public.is_league_member(league_id));

drop policy if exists "dropped_players_read" on public.dropped_players;
create policy "dropped_players_read" on public.dropped_players
    for select using (public.is_league_member(league_id));

drop policy if exists "drafts_read" on public.drafts;
create policy "drafts_read" on public.drafts
    for select using (public.is_league_member(league_id));

drop policy if exists "draft_picks_read" on public.draft_picks;
create policy "draft_picks_read" on public.draft_picks
    for select using (
        exists (select 1 from public.drafts d
                where d.id = draft_picks.draft_id
                  and public.is_league_member(d.league_id))
    );

-- waiver_claims: pending rows stay owner-only (blind FAAB bids); resolved
-- rows go from any-authenticated to league members.
drop policy if exists "waiver_claims_read" on public.waiver_claims;
create policy "waiver_claims_read" on public.waiver_claims
    for select using (
        public.is_league_member(league_id)
        and (
            status <> 'pending'
            or exists (select 1 from public.teams t
                       where t.id = waiver_claims.team_id
                         and t.owner_id = auth.uid())
        )
    );
