import SwiftUI

// League tab root: the league-wide hub. The overview homepage (progress,
// scoreboard, standings, team stats, information environment) is the landing
// content, with the draft callout / commissioner draft-scheduling CTA above
// and drill rows into the deeper league surfaces (playoffs, draft review,
// history, teams, invite link, commissioner settings). This absorbed
// everything the deleted LeagueDetailView hosted — structure for the 5-tab
// shell, not a redesign.
struct LeagueHubView: View {
    @Environment(AppState.self) private var app

    // The league's draft as last fetched, complete or not. The callout /
    // scheduling CTA derive from it: activeDraft only surfaces unfinished
    // drafts, while a nil `draft` is what unlocks "Schedule the draft".
    @State private var draft: Draft? = nil
    @State private var viewingTeam: FantasyTeam? = nil
    @State private var editingTeam: FantasyTeam? = nil
    @State private var customizingTeam: FantasyTeam? = nil
    @State private var showingSettings = false
    @State private var showingDraftSettings = false
    // Promoted Sleeper leagues have history backfilled before any season
    // completes here.
    @State private var hasHistory = false

    private var league: League? { app.selectedLeague }

    private var activeDraft: Draft? {
        draft.flatMap { $0.status == .complete ? nil : $0 }
    }

    // Pushed destinations for the deeper league surfaces.
    enum HubDestination: Hashable {
        case playoffs, draftReview, history, teams
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("League")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .leagueSwitcher()
            .navigationDestination(for: HubDestination.self) { dest in
                hubDestination(dest)
            }
        }
        .task(id: app.selectedLeagueID) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .draftUpdated)) { _ in
            Task { await refreshDraftStatus() }
        }
        .sheet(item: $viewingTeam) { team in
            if let league {
                TeamRosterSheet(league: league, team: team, onEdit: {
                    // Hop from the read-only roster popup straight into the
                    // editor. The popup dismisses itself before invoking us;
                    // defer the second sheet by a tick so the first one has
                    // fully unwound — SwiftUI drops back-to-back sheets that
                    // race the same presenter.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        editingTeam = team
                    }
                }, onCustomize: {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        customizingTeam = team
                    }
                })
            }
        }
        .sheet(item: $editingTeam) { team in
            if let league {
                RosterEditorView(league: league, team: team) { updated in
                    app.selectedLeague = updated
                }
            }
        }
        .sheet(item: $customizingTeam) { team in
            if let league {
                TeamCustomizationSheet(league: league, team: team) { updated in
                    app.selectedLeague = updated
                }
            }
        }
        .sheet(isPresented: $showingDraftSettings) {
            // Sheet (not push) — DraftSetupView wraps its own NavigationStack
            // and nesting that into a parent NavigationStack pops the user
            // back to the league picker.
            if let league {
                DraftSetupView(league: league, existing: draft) { updated in
                    self.draft = updated
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            if let league {
                LeagueSettingsView(
                    league: league,
                    onSave: { app.selectedLeague = $0 },
                    onDelete: {
                        // League is gone — return to the overview and refresh
                        // summaries so the deleted row drops out.
                        Task {
                            await app.reloadLeagues()
                            await app.selectLeague(nil)
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let league {
            ScrollView {
                VStack(spacing: FFSpace.l) {
                    draftCallout(league)
                    draftSchedulingRow(league)
                    // The full overview homepage (sim control strip, champion
                    // banner, progress, scoreboard, standings, team stats,
                    // information environment) — rehomed from the deleted
                    // LeagueDetailView's Overview segment.
                    SimulationOverviewView(
                        league: league,
                        onLeagueUpdate: { app.selectedLeague = $0 },
                        onTapTeam: { viewingTeam = $0 }
                    )
                    drillRows(league)
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.s)
                // Clear the tab bar + collapsed league-chat peek that overlay
                // the bottom (matches the other tab roots).
                .padding(.bottom, 80)
            }
            .refreshable { await load() }
            // Re-check on pop-back so the callout clears right after a draft
            // completes or a mock is discarded.
            .onAppear { Task { await refreshDraftStatus() } }
        } else {
            Spacer()
        }
    }

    // MARK: - Draft callout

    // Commissioner-only draft scheduling, rehomed from the deleted
    // LeagueDetailView: no draft yet → the "Schedule the draft" CTA; a
    // scheduled draft → a quiet "Draft settings" row to adjust it. Sims
    // auto-create their draft on construction, so the CTA only makes sense
    // in standard leagues.
    @ViewBuilder
    private func draftSchedulingRow(_ league: League) -> some View {
        if league.creatorID == app.session?.userID {
            if draft == nil && !league.isTest {
                Button {
                    showingDraftSettings = true
                } label: {
                    HStack {
                        Image(systemName: "calendar.badge.plus")
                            .foregroundStyle(FFColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Schedule the draft").font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                            Text("Set a date and pick order to get the season going.")
                                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    .ffCard()
                }
                .buttonStyle(.plain)
            } else if draft?.status == .scheduled {
                Button {
                    showingDraftSettings = true
                } label: {
                    hubRowLabel("Draft settings", icon: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Same active-draft callout as the Team tab.
    @ViewBuilder
    private func draftCallout(_ league: League) -> some View {
        if let draft = activeDraft {
            NavigationLink {
                DraftRoomView(leagueID: league.id)
            } label: {
                HStack(spacing: FFSpace.m) {
                    Image(systemName: draft.status == .live ? "dot.radiowaves.left.and.right" : "calendar.badge.clock")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(draft.status == .live ? FFColor.accent : FFColor.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.status == .live ? "Draft is live" :
                             draft.status == .paused ? "Draft paused" : "Draft scheduled")
                            .font(.ffHeadline)
                            .foregroundStyle(FFColor.textPrimary)
                        Text(draft.status == .live
                             ? "Jump into the draft room — picks are rolling."
                             : "Starts \(draft.startsAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .padding(FFSpace.l)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(draft.status == .live ? FFColor.accent.opacity(0.5) : FFColor.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Drill rows

    private func drillRows(_ league: League) -> some View {
        VStack(spacing: FFSpace.s) {
            if league.playoffTeams >= 2 {
                hubRow("Playoffs", icon: "trophy", value: .playoffs)
            }
            hubRow("Draft", icon: "list.number", value: .draftReview)
            if showsHistory(league) {
                hubRow("History", icon: "clock.arrow.circlepath", value: .history)
            }
            hubRow("Teams", icon: "person.3", value: .teams)
            // Any member can share the join link (rehomed from the deleted
            // LeagueDetailView's toolbar; Settings has a commish-only copy).
            if let url = JoinLink.url(forCode: league.joinCode) {
                ShareLink(
                    item: url,
                    subject: Text("Join \(league.name) on Tarsa Fantasy"),
                    message: Text("Tap to claim a team in \(league.name).")
                ) {
                    hubRowLabel("Invite members", icon: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            if league.creatorID == app.session?.userID {
                // Sheet (not push) — LeagueSettingsView wraps its own
                // NavigationStack; nesting it into ours would fight the
                // parent stack.
                Button { showingSettings = true } label: {
                    hubRowLabel("Settings", icon: "gearshape")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func hubRow(_ title: String, icon: String, value: HubDestination) -> some View {
        NavigationLink(value: value) {
            hubRowLabel(title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func hubRowLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: FFSpace.m) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FFColor.accent)
                .frame(width: 24)
            Text(title)
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
        .contentShape(RoundedRectangle(cornerRadius: FFRadius.m))
    }

    // MARK: - Pushed destinations

    @ViewBuilder
    private func hubDestination(_ dest: HubDestination) -> some View {
        if let league {
            switch dest {
            case .playoffs:
                hubScreen("Playoffs") { PlayoffBracketView(league: league) }
            case .draftReview:
                hubScreen("Draft") { SimulationDraftReviewView(league: league) }
            case .history:
                hubScreen("History") { LeagueHistoryView(league: league) }
            case .teams:
                hubScreen("Teams") { LeagueTeamsList(league: league) }
            }
        }
    }

    // Standard scroll chrome around a section view — the framing every
    // league surface shares.
    private func hubScreen<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: FFSpace.l) { content() }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 80)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
    }

    // MARK: - Load

    private func load() async {
        guard let league else {
            draft = nil
            hasHistory = false
            return
        }
        await app.loadSeason(league.season)
        await app.loadLeagueNicknames(leagueID: league.id)
        await refreshDraftStatus()
        if let imp = app.importedSleeperLeagues.first(where: { $0.activatedLeagueID == league.id }) {
            hasHistory = imp.seasons.contains { $0.seasonYear < imp.seasonYear }
        } else {
            hasHistory = false
        }
    }

    private func refreshDraftStatus() async {
        guard let league else { draft = nil; return }
        draft = await app.draft(leagueID: league.id)
    }

    private func showsHistory(_ lg: League) -> Bool {
        !lg.isTest && (lg.seasonCompleted || lg.parentLeagueID != nil || hasHistory)
    }
}

// Simple franchise browser for the hub's Teams row: every team with its
// crest and roster size; tap for the read-only roster popup.
private struct LeagueTeamsList: View {
    @Environment(AppState.self) private var app
    let league: League

    @State private var viewingTeam: FantasyTeam? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(league.teams) { team in
                Button { viewingTeam = team } label: {
                    HStack(spacing: FFSpace.m) {
                        TeamCrestView(team: team, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(team.name)
                                .font(.ffBody)
                                .foregroundStyle(FFColor.textPrimary)
                                .lineLimit(1)
                            Text("\(team.roster.count) players")
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                        Spacer()
                        if team.ownerID == app.session?.userID {
                            Text("YOU").ffEyebrow(color: FFColor.accent)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    .padding(.horizontal, FFSpace.m)
                    .padding(.vertical, FFSpace.s)
                    .ffHairlineBottom()
                }
                .buttonStyle(.plain)
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
        .sheet(item: $viewingTeam) { team in
            TeamRosterSheet(league: league, team: team)
        }
    }
}
