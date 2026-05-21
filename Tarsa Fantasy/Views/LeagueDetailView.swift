import SwiftUI

struct LeagueDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let leagueID: String

    @State private var league: League? = nil
    @State private var draft: Draft? = nil
    @State private var simSection: SimSection = .overview
    @State private var week: Int = 1
    @State private var editingTeam: FantasyTeam? = nil
    @State private var viewingTeam: FantasyTeam? = nil
    @State private var showingSettings: Bool = false
    @State private var showingDraftRoom: Bool = false
    @State private var showingDraftSettings: Bool = false
    @State private var lineupEdit: LineupEditTarget? = nil

    struct LineupEditTarget: Identifiable {
        let team: FantasyTeam
        let week: Int
        var id: String { "\(team.id)-\(week)" }
    }

    // Unified section set used for both simulation and standard leagues.
    // Standard leagues additionally surface History (when available);
    // sims keep the original four-tab strategy-testing layout. Chat
    // lives at the top-level Chat tab, not in here.
    enum SimSection: String, CaseIterable, Identifiable {
        case overview, week, playoffs, draft, manage, history
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: return "Overview"
            case .week:     return "Matchup"
            case .playoffs: return "Playoffs"
            case .draft:    return "Draft"
            case .manage:   return "Manage"
            case .history:  return "History"
            }
        }
    }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            if let league {
                ScrollView {
                    VStack(spacing: FFSpace.l) {
                        simulationContent(league)
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.bottom, 40)
                }
            } else {
                ProgressView().tint(FFColor.accent)
            }
        }
        .navigationTitle(league?.name ?? "League")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .toolbar {
            if let lg = league {
                if let url = JoinLink.url(forCode: lg.joinCode) {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(
                            item: url,
                            subject: Text("Join \(lg.name) on Tarsa Fantasy"),
                            message: Text("Tap to claim a team in \(lg.name).")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(FFColor.textPrimary)
                        }
                    }
                }
                if lg.creatorID == app.session?.userID {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(FFColor.textPrimary)
                        }
                    }
                }
            }
        }
        .task(id: leagueID) { await loadLeague() }
        .onChange(of: showingDraftRoom) { _, visible in
            if !visible {
                Task { draft = await app.draft(leagueID: leagueID) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .draftUpdated)) { _ in
            Task { draft = await app.draft(leagueID: leagueID) }
        }
        .sheet(item: $editingTeam) { team in
            if let league {
                RosterEditorView(league: league, team: team) { updated in
                    self.league = updated
                }
            }
        }
        .sheet(item: $viewingTeam) { team in
            if let league {
                TeamRosterSheet(league: league, team: team) {
                    // Hop from the read-only roster popup straight into the
                    // editor. The popup dismisses itself before invoking us;
                    // defer the second sheet by a tick so the first one has
                    // fully unwound — SwiftUI drops back-to-back sheets that
                    // race the same presenter.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        editingTeam = team
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            if let league {
                LeagueSettingsView(
                    league: league,
                    onSave: { updated in self.league = updated },
                    onDelete: {
                        // League is gone — pop back to the leagues list and
                        // refresh summaries so the deleted row drops out.
                        Task { await app.reloadLeagues() }
                        dismiss()
                    }
                )
            }
        }
        .navigationDestination(isPresented: $showingDraftRoom) {
            DraftRoomView(leagueID: leagueID)
        }
        .sheet(isPresented: $showingDraftSettings) {
            if let league {
                DraftSetupView(league: league, existing: draft) { updated in
                    self.draft = updated
                }
            }
        }
        .sheet(item: $lineupEdit) { target in
            if let league {
                LineupEditorView(league: league, team: target.team, week: target.week) { updated in
                    self.league = updated
                }
            }
        }
    }

    // Unified page composition. Strategy-testing layout for both sim and
    // standard leagues: Overview homepage (scoreboard + standings, with a
    // tap-a-team-name popup for rosters), weekly matchup with full game
    // context, draft post-mortem, waivers management. Standard leagues
    // additionally surface History (when available).
    @ViewBuilder
    private func simulationContent(_ lg: League) -> some View {
        // Show the live/scheduled draft banner whenever a draft exists and
        // hasn't completed. Sims auto-create their draft on construction
        // so the "schedule the draft" CTA only makes sense in standard
        // leagues where a draft may not yet exist.
        if draft != nil || !lg.isTest {
            draftBanner(lg)
        }
        sectionPicker(for: lg)
        switch simSection {
        case .overview:
            SimulationOverviewView(
                league: lg,
                onLeagueUpdate: { updated in self.league = updated },
                onTapTeam: { team in viewingTeam = team }
            )
        case .week:
            simulationWeekTab(lg)
        case .playoffs:
            PlayoffBracketView(league: lg)
        case .draft:
            SimulationDraftReviewView(league: lg)
        case .manage:
            WaiversView(league: lg) { updated in self.league = updated }
        case .history:
            LeagueHistoryView(league: lg)
        }
    }

    private func visibleSections(for lg: League) -> [SimSection] {
        var sections: [SimSection] = [.overview, .week]
        if lg.playoffTeams >= 2 { sections.append(.playoffs) }
        sections.append(contentsOf: [.draft, .manage])
        if !lg.isTest, lg.seasonCompleted || lg.parentLeagueID != nil {
            sections.append(.history)
        }
        return sections
    }

    private func sectionPicker(for lg: League) -> some View {
        let visible = visibleSections(for: lg)
        return SegmentedTabPicker(items: visible, selection: $simSection) {
            Text($0.label)
        }
        .onAppear {
            // Snap back to Overview if the current selection isn't valid
            // for this league (e.g. History was visible on a wrapped season
            // and we navigate to a league where it's not).
            if !visible.contains(simSection) { simSection = .overview }
        }
    }

    private func simulationWeekTab(_ lg: League) -> some View {
        let weeks = lg.schedule.map(\.week)
        let simWeek = max(1, min(lg.schedule.count, lg.simulatedWeek ?? 1))
        return MatchupView(league: lg, week: $week, onEditLineup: { team, w in
            lineupEdit = LineupEditTarget(team: team, week: w)
        })
            .onAppear {
                // Snap to the simulated week the first time the tab opens
                // so the user lands on the "live" matchup.
                if !weeks.contains(week) { week = simWeek }
            }
    }

    private func loadLeague() async {
        league = await app.league(leagueID)
        await app.loadSeason(league?.season ?? app.selectedSeason)
        if let plan = league?.schedule.first { week = plan.week }
        draft = await app.draft(leagueID: leagueID)
    }

    @ViewBuilder
    private func draftBanner(_ lg: League) -> some View {
        if let draft, draft.status != .complete {
            // Wrap in a TimelineView so canEnter re-evaluates each second.
            // Without this, a scheduled draft whose startsAt has just crossed
            // T-0 never re-renders the surrounding view, so the "Enter draft
            // room" button doesn't appear until the user navigates away and
            // back (which forces a state reload).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                draftBannerContent(lg, draft: draft, now: context.date)
            }
        } else if draft == nil && lg.creatorID == app.session?.userID {
            // No draft yet — surface a setup CTA for the commissioner.
            // Sheet-based for the same reason as the gear icon above:
            // DraftSetupView's own NavigationStack collides with the parent.
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
        }
    }

    private func draftBannerContent(_ lg: League, draft: Draft, now: Date) -> some View {
        let isCommish = lg.creatorID == app.session?.userID
        let canEnter  = draft.status == .live
            || draft.status == .scheduled
            || draft.status == .paused
        let beforeStart = draft.status == .scheduled && draft.startsAt > now
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draftBannerEyebrow(draft).0).ffEyebrow(color: draftBannerEyebrow(draft).1)
                    Text(draftBannerTitle(draft))
                        .font(.ffHeadline)
                        .foregroundStyle(FFColor.textPrimary)
                }
                Spacer()
                if isCommish && draft.status == .scheduled {
                    // Sheet (not NavigationLink) — DraftSetupView wraps its
                    // own NavigationStack and nesting that into a parent
                    // NavigationStack pops the user back to the league
                    // picker.
                    Button {
                        showingDraftSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(FFColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if canEnter {
                if beforeStart {
                    Text("Starts in \(formatStartsFrom(draft.startsAt, now: now))")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                }
                Button {
                    showingDraftRoom = true
                } label: {
                    Text(draft.status == .live ? "Enter draft room" : "Open draft room")
                        .ffPrimaryButton()
                }
                .buttonStyle(.plain)
            }
        }
        .ffCard()
    }

    private func formatStartsFrom(_ d: Date, now: Date) -> String {
        let s = max(0, Int(d.timeIntervalSince(now).rounded(.up)))
        if s >= 86400 { return "\(s/86400)d \((s%86400)/3600)h" }
        if s >= 3600  { return String(format: "%dh %02dm", s/3600, (s%3600)/60) }
        if s >= 60    { return String(format: "%dm %02ds", s/60, s%60) }
        return "\(s)s"
    }

    private func draftBannerEyebrow(_ d: Draft) -> (String, Color) {
        switch d.status {
        case .scheduled: return ("DRAFT", FFColor.textTertiary)
        case .live:      return ("DRAFT · LIVE", FFColor.accent)
        case .paused:    return ("DRAFT · PAUSED", FFColor.warning)
        case .complete:  return ("DRAFT · COMPLETE", FFColor.positive)
        }
    }

    private func draftBannerTitle(_ d: Draft) -> String {
        switch d.status {
        case .scheduled:
            let when = d.startsAt.formatted(date: .abbreviated, time: .shortened)
            return "Scheduled for \(when)"
        case .live:
            return "Round \(d.currentRound), pick \(d.currentPick)/\(d.totalPicks)"
        case .paused:
            return "Paused at pick \(d.currentPick)"
        case .complete:
            return "Wrapped"
        }
    }

}
