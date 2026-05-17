import SwiftUI

struct LeagueDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let leagueID: String

    @State private var league: League? = nil
    @State private var draft: Draft? = nil
    @State private var section: Section = .standings
    @State private var simSection: SimSection = .overview
    @State private var week: Int = 1
    @State private var editingTeam: FantasyTeam? = nil
    @State private var viewingTeam: FantasyTeam? = nil
    @State private var pendingEdit: FantasyTeam? = nil
    @State private var showingSettings: Bool = false
    @State private var showingDraftRoom: Bool = false
    @State private var showingDraftSettings: Bool = false

    enum Section: String, CaseIterable, Identifiable {
        case standings, matchup, waivers, chat, history
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    // Simulation-specific section set. Keeps strategy testing front-and-
    // center: where you are in the season, this week's matchup with full
    // game-environment context, how your draft pans out, manage rosters.
    enum SimSection: String, CaseIterable, Identifiable {
        case overview, week, draft, manage
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: return "Overview"
            case .week:     return "Matchup"
            case .draft:    return "Draft"
            case .manage:   return "Manage"
            }
        }
    }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            if let league {
                if league.isTest {
                    ScrollView {
                        VStack(spacing: FFSpace.l) {
                            simulationContent(league)
                        }
                        .padding(.horizontal, FFSpace.l)
                        .padding(.bottom, 40)
                    }
                } else if section == .chat {
                    // Chat owns its own scroll + composer and needs the
                    // full vertical space, so it lives OUTSIDE the parent
                    // ScrollView. Keep hero/draftBanner pinned above to
                    // preserve navigation context.
                    VStack(spacing: 0) {
                        VStack(spacing: FFSpace.l) {
                            sectionPicker(for: league)
                        }
                        .padding(.horizontal, FFSpace.l)
                        .padding(.top, FFSpace.l)
                        LeagueChatView(league: league)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: FFSpace.l) {
                            hero(league)
                            draftBanner(league)
                            sectionPicker(for: league)
                            switch section {
                            case .standings:  standingsView(league)
                            case .matchup:    MatchupView(league: league, week: $week)
                            case .waivers:
                                WaiversView(league: league) { updated in
                                    self.league = updated
                                }
                            case .chat:
                                EmptyView()    // handled by the branch above
                            case .history:
                                LeagueHistoryView(league: league)
                            }
                        }
                        .padding(.horizontal, FFSpace.l)
                        .padding(.bottom, 40)
                    }
                }
            } else {
                ProgressView().tint(FFColor.accent)
            }
        }
        .navigationTitle(league?.name ?? "League")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .toolbar {
            if let lg = league, lg.creatorID == app.session?.userID {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(FFColor.textPrimary)
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
                rosterSheet(team: team, lg: league)
            }
        }
        .onChange(of: viewingTeam) { _, new in
            // Hand off from view → edit: SwiftUI can't reliably present a
            // second sheet while another is dismissing, so we wait for the
            // viewing sheet to fully drop before opening the editor.
            guard new == nil, let pending = pendingEdit else { return }
            pendingEdit = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                editingTeam = pending
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
    }

    // Simulation-specific page composition. Different hero + section set
    // tailored to strategy-testing workflows: where you are in the season,
    // weekly matchup analysis with full game context, draft post-mortem.
    @ViewBuilder
    private func simulationContent(_ lg: League) -> some View {
        // Live-draft sims still need the draft banner up top; once drafted
        // the user lands on Overview.
        if let d = draft, d.status != .complete {
            draftBanner(lg)
        }
        SegmentedTabPicker(items: SimSection.allCases, selection: $simSection) {
            Text($0.label)
        }
        switch simSection {
        case .overview:
            SimulationOverviewView(league: lg) { updated in self.league = updated }
        case .week:
            simulationWeekTab(lg)
        case .draft:
            SimulationDraftReviewView(league: lg)
        case .manage:
            rostersView(lg)
            WaiversView(league: lg) { updated in self.league = updated }
        }
    }

    private func simulationWeekTab(_ lg: League) -> some View {
        let weeks = lg.schedule.map(\.week)
        let simWeek = max(1, min(lg.schedule.count, lg.simulatedWeek ?? 1))
        return MatchupView(league: lg, week: $week)
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
            || (draft.status == .scheduled && draft.startsAt <= now)
            || draft.status == .paused
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
                Button {
                    showingDraftRoom = true
                } label: {
                    Text(draft.status == .live ? "Enter draft room" : "Open draft room")
                        .ffPrimaryButton()
                }
                .buttonStyle(.plain)
            } else if draft.status == .scheduled {
                Text("Starts in \(formatStartsFrom(draft.startsAt, now: now))")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
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

    private func formatStarts(_ d: Date) -> String {
        let s = max(0, Int(d.timeIntervalSinceNow.rounded(.up)))
        if s >= 86400 { return "\(s/86400)d \((s%86400)/3600)h" }
        if s >= 3600  { return String(format: "%dh %02dm", s/3600, (s%3600)/60) }
        if s >= 60    { return String(format: "%dm %02ds", s/60, s%60) }
        return "\(s)s"
    }

    private var myTeam: FantasyTeam? {
        guard let uid = app.session?.userID else { return nil }
        return league?.teams.first(where: { $0.ownerID == uid })
    }

    // MARK: - Hero

    private func hero(_ lg: League) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR TEAM").ffEyebrow(color: FFColor.textTertiary)
                    HStack(spacing: FFSpace.s) {
                        Text(myTeam?.name ?? "Spectating")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                        if lg.creatorID == app.session?.userID {
                            CommissionerBadge()
                        }
                    }
                }
                Spacer()
            }

            heroStats(lg)

            HStack(spacing: FFSpace.s) {
                FFPill { Text(String(lg.season)) }
                FFPill { Text(lg.scoring.label.uppercased()) }
                FFPill { Text("\(lg.teams.count) TEAMS") }
            }
        }
        .ffCard(padding: FFSpace.xl)
        .padding(.top, FFSpace.s)
    }

    @ViewBuilder
    private func heroStats(_ lg: League) -> some View {
        let players = Fantasy.playersFor(league: lg, snapshot: app.players(season: lg.season))
        let standings = Fantasy.standings(league: lg, players: players)
        let mine = standings.first(where: { $0.id == myTeam?.id })

        HStack(alignment: .top, spacing: FFSpace.xl) {
            statBlock(label: "RECORD",
                      value: mine.map { "\($0.wins)–\($0.losses)\($0.ties > 0 ? "–\($0.ties)" : "")" } ?? "—")
            divider
            statBlock(label: "POINTS FOR", value: mine.map { $0.pointsFor.fpString } ?? "—")
            divider
            statBlock(label: "RANK",
                      value: mine.map { "#\($0.rank)" } ?? "—",
                      color: mine?.rank == 1 ? FFColor.accent : FFColor.textPrimary)
        }
    }

    private var divider: some View {
        Rectangle().fill(FFColor.border).frame(width: 1, height: 36)
    }

    private func statBlock(label: String, value: String, color: Color = FFColor.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value)
                .font(.ffStatMedium)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section picker

    private func sectionPicker(for league: League) -> some View {
        // History tab only appears for leagues with archives reachable —
        // i.e., this season has been completed OR there's a parent league
        // in the chain.
        let visible = Section.allCases.filter {
            $0 != .history || league.seasonCompleted || league.parentLeagueID != nil
        }
        return SegmentedTabPicker(items: visible, selection: $section) {
            Text($0.label)
        }
        .onAppear {
            // Snap back to standings if history was selected but is no
            // longer available (e.g., view reopened with stale state).
            if !visible.contains(section) { section = .standings }
        }
    }

    // MARK: - Standings

    @ViewBuilder
    private func standingsView(_ lg: League) -> some View {
        let players = Fantasy.playersFor(league: lg, snapshot: app.players(season: lg.season))
        let rows = Fantasy.standings(league: lg, players: players)
        let myID = myTeam?.id

        VStack(spacing: 0) {
            HStack {
                Text("#").ffEyebrow(color: FFColor.textTertiary).frame(width: 28, alignment: .leading)
                Text("TEAM").ffEyebrow(color: FFColor.textTertiary)
                Spacer()
                Text("PF").ffEyebrow(color: FFColor.textTertiary)
                    .frame(width: 60, alignment: .trailing)
                Text("REC").ffEyebrow(color: FFColor.textTertiary)
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.vertical, FFSpace.s)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    let team = lg.teams.first(where: { $0.id == row.id })
                    Button {
                        viewingTeam = team
                    } label: {
                        standingsRow(row, isMe: row.id == myID)
                    }
                    .buttonStyle(.plain)
                    .disabled(team == nil)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func standingsRow(_ row: StandingsRow, isMe: Bool) -> some View {
        HStack {
            Text("\(row.rank)")
                .font(.ffStatSmall)
                .foregroundStyle(isMe ? FFColor.accent : FFColor.textSecondary)
                .frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.ffHeadline)
                    .foregroundStyle(isMe ? FFColor.textPrimary : FFColor.textPrimary)
                if isMe {
                    Text("YOU").ffEyebrow(color: FFColor.accent)
                }
            }
            Spacer()
            Text(row.pointsFor.fpString)
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.textPrimary)
                .frame(width: 60, alignment: .trailing)
            Text("\(row.wins)–\(row.losses)")
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.textSecondary)
                .frame(width: 50, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
                .padding(.leading, FFSpace.s)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .background(isMe ? FFColor.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .ffHairlineBottom()
    }

    // MARK: - Rosters

    @ViewBuilder
    private func rostersView(_ lg: League) -> some View {
        let players = Fantasy.playersFor(league: lg, snapshot: app.players(season: lg.season))
        let config = lg.rosterConfig
        let uid = app.session?.userID
        let isCommish = lg.creatorID == uid
        let ordered = lg.teams.sorted { a, b in
            (a.ownerID == uid && b.ownerID != uid)
                || (a.ownerID != nil && b.ownerID == nil)
        }
        VStack(spacing: FFSpace.l) {
            ForEach(ordered) { team in
                teamCard(
                    team: team, config: config, players: players, scoring: lg.scoring,
                    isMine: team.ownerID == uid, isCommish: isCommish
                )
            }
        }
    }

    @ViewBuilder
    private func rosterSheet(team: FantasyTeam, lg: League) -> some View {
        let players = Fantasy.playersFor(league: lg, snapshot: app.players(season: lg.season))
        let uid = app.session?.userID
        let isMine = team.ownerID == uid
        let isCommish = lg.creatorID == uid
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    teamCard(
                        team: team, config: lg.rosterConfig, players: players,
                        scoring: lg.scoring, isMine: isMine, isCommish: isCommish,
                        onEdit: { t in
                            pendingEdit = t
                            viewingTeam = nil
                        }
                    )
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.l)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(team.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { viewingTeam = nil }
                        .foregroundStyle(FFColor.accent)
                }
            }
        }
    }

    private func teamCard(team: FantasyTeam, config: RosterConfig,
                          players: [String: Player], scoring: Scoring,
                          isMine: Bool, isCommish: Bool,
                          onEdit: ((FantasyTeam) -> Void)? = nil) -> some View {
        let (starters, bench) = Fantasy.resolveLineup(team: team, players: players, config: config, scoring: scoring)
        return VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack(spacing: FFSpace.s) {
                Text(team.name).font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                if isMine {
                    Text("YOU").ffEyebrow(color: FFColor.accent)
                } else if team.ownerID == nil {
                    Text("OPEN").ffEyebrow(color: FFColor.warning)
                }
                Spacer()
                Text("\(team.roster.count)/\(config.totalSize)")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textTertiary)
            }

            if team.roster.isEmpty {
                Text("No players yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(.vertical, FFSpace.m)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(zip(config.starterSlots, starters).enumerated()), id: \.offset) { _, pair in
                        lineupRow(slot: pair.0, playerID: pair.1, players: players, scoring: scoring)
                    }
                }

                if !bench.isEmpty {
                    Text("Bench").ffEyebrow().padding(.top, FFSpace.s)
                    VStack(spacing: 0) {
                        ForEach(bench, id: \.self) { pid in
                            lineupRow(slot: .bench, playerID: pid, players: players, scoring: scoring)
                        }
                    }
                }
            }

            if isMine || isCommish {
                Button {
                    if let onEdit { onEdit(team) } else { editingTeam = team }
                } label: {
                    HStack {
                        Image(systemName: isMine ? "square.and.pencil" : "shield.lefthalf.filled")
                            .font(.system(size: 13, weight: .semibold))
                        Text(isMine ? "Edit roster" : "Edit roster (commish)")
                    }
                    .frame(maxWidth: .infinity)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.accent)
                    .padding(.vertical, 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.s)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, FFSpace.s)
            }
        }
        .ffCard()
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(isMine ? FFColor.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private func lineupRow(slot: LineupSlot, playerID: String,
                           players: [String: Player], scoring: Scoring) -> some View {
        let player = playerID.isEmpty ? nil : players[playerID]
        let summary = player.map { Fantasy.summary($0, scoring: scoring) }
        return HStack(spacing: FFSpace.m) {
            Text(slot.label)
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
                .frame(width: 40, alignment: .leading)
            if let summary {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: summary.position)
                        Text(summary.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    }
                }
                Spacer()
                Text(summary.points.fpString)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textPrimary)
            } else {
                Text("Empty")
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textTertiary)
                Spacer()
            }
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }
}
