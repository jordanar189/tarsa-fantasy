import SwiftUI

// The app's home base when no league is in focus: pick, create, or join a
// league, and reach direct messages. Selecting a league hands off to the
// league-centric tab shell.
struct LeagueOverviewView: View {
    @Environment(AppState.self) private var app
    @State private var showingCreate = false
    @State private var showingMessages = false
    @State private var showingSleeperImport = false
    @State private var showingMockDraft = false
    @State private var importedSelection: String? = nil
    @State private var joinSheet: JoinSheet? = nil

    // Drives the join sheet. `code` is non-nil when opened from an invite
    // link (pre-filled + auto-looked-up); nil for manual entry.
    struct JoinSheet: Identifiable {
        let id = UUID()
        let code: String?
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                if app.leagueSummaries.isEmpty && app.importedSleeperLeagues.isEmpty {
                    FFGlow(intensity: 0.7).ignoresSafeArea()
                }
                content
            }
            .navigationTitle("Your leagues")
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingMessages = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(FFColor.textPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
            .sheet(isPresented: $showingCreate) { CreateLeagueView() }
            .sheet(isPresented: $showingMessages) { ChatView() }
            .sheet(isPresented: $showingSleeperImport) {
                SleeperImportView { id in importedSelection = id }
            }
            .sheet(isPresented: $showingMockDraft) { MockDraftSetupView() }
            .sheet(item: $joinSheet) { sheet in
                JoinLeagueView(initialCode: sheet.code) { id in
                    Task { await app.selectLeague(id) }
                }
            }
            .navigationDestination(item: $importedSelection) { id in
                ImportedLeagueDetailView(leagueID: id)
            }
            .task { await app.reloadLeagues() }
            .onAppear { consumePendingJoin() }
            .onChange(of: app.pendingJoinCode) { _, _ in consumePendingJoin() }
        }
    }

    private func consumePendingJoin() {
        guard let code = app.pendingJoinCode else { return }
        joinSheet = JoinSheet(code: code)
        app.pendingJoinCode = nil
    }

    @ViewBuilder
    private var content: some View {
        if app.leagueSummaries.isEmpty && app.importedSleeperLeagues.isEmpty {
            empty
        } else {
            list
        }
    }

    private var empty: some View {
        VStack(spacing: FFSpace.xxl) {
            Spacer()
            VStack(spacing: FFSpace.l) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(FFGradient.brand)
                    .shadow(color: FFBrand.violet.opacity(0.4), radius: 18, y: 8)
                VStack(spacing: FFSpace.xs) {
                    Text("Your trophy case is empty")
                        .font(.ffTitle).foregroundStyle(FFColor.textPrimary)
                    Text("Start a league, or join one with an invite link.\nA championship has to start somewhere.")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            VStack(spacing: FFSpace.s) {
                Button("Create a league") { showingCreate = true }
                    .ffPrimaryButton()
                Button("Join a league") { joinSheet = JoinSheet(code: nil) }
                    .ffSecondaryButton()
                Button("Import from Sleeper") { showingSleeperImport = true }
                    .ffSecondaryButton()
            }
            .padding(.horizontal, FFSpace.xxl)
            Spacer()
            Spacer()
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: FFSpace.m) {
                actionRow(icon: "plus", title: "Create a league", subtitle: "Set your roster, invite friends") {
                    showingCreate = true
                }
                actionRow(icon: "person.badge.plus", title: "Join a league", subtitle: "Claim a team with an invite link or code") {
                    joinSheet = JoinSheet(code: nil)
                }
                actionRow(icon: "square.and.arrow.down", title: "Import from Sleeper", subtitle: "Bring in rosters, history & transactions") {
                    showingSleeperImport = true
                }
                actionRow(icon: "stopwatch", title: "Mock draft", subtitle: "Practice against instant-pick bots") {
                    showingMockDraft = true
                }

                if !app.leagueSummaries.isEmpty {
                    HStack {
                        Text("Your leagues").ffEyebrow()
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, FFSpace.s)

                    ForEach(app.leagueSummaries) { lg in
                        Button {
                            Task { await app.selectLeague(lg.id) }
                        } label: {
                            LeagueListRow(summary: lg)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await app.deleteLeague(lg.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                if !app.importedSleeperLeagues.isEmpty {
                    HStack {
                        Text("Imported from Sleeper").ffEyebrow()
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, FFSpace.s)

                    ForEach(app.importedSleeperLeagues) { lg in
                        Button {
                            importedSelection = lg.id
                        } label: {
                            ImportedLeagueRow(league: lg)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                app.deleteImportedSleeperLeague(id: lg.id)
                            } label: {
                                Label("Remove import", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(FFSpace.l)
        }
    }

    private func actionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FFSpace.l) {
                ZStack {
                    Circle().fill(FFGradient.brand)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                .shadow(color: FFBrand.violet.opacity(0.30), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                    Text(subtitle).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
            }
            .ffCard(padding: FFSpace.l)
        }
        .buttonStyle(.plain)
    }
}

struct LeagueListRow: View {
    @Environment(AppState.self) private var app
    let summary: LeagueSummary

    private var isCommish: Bool { summary.creatorID == app.session?.userID }

    var body: some View {
        HStack(spacing: FFSpace.l) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: FFSpace.s) {
                    Text(summary.name)
                        .font(.ffHeadline)
                        .foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                    if isCommish { CommissionerBadge(compact: true) }
                }
                HStack(spacing: FFSpace.s) {
                    if summary.isTest {
                        FFPill { Text("SIM").foregroundStyle(FFColor.warning) }
                    }
                    if summary.isDynasty {
                        FFPill { Text("DYNASTY").foregroundStyle(FFColor.accent) }
                    }
                    FFPill { Text(String(summary.season)) }
                    FFPill { Text(summary.scoring.label.uppercased()) }
                    FFPill { Text("\(summary.teamCount) TEAMS") }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }
}

struct ImportedLeagueRow: View {
    let league: ImportedLeague

    var body: some View {
        HStack(spacing: FFSpace.l) {
            SleeperAvatar(id: league.latest?.avatar, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(league.name)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1)
                HStack(spacing: FFSpace.s) {
                    if league.isActivated {
                        FFPill { Text("ACTIVE").foregroundStyle(FFColor.positive) }
                    } else {
                        FFPill { Text("SLEEPER").foregroundStyle(FFColor.accent) }
                    }
                    if league.seasonYear > 0 { FFPill { Text(String(league.seasonYear)) } }
                    if !league.scoringLabel.isEmpty { FFPill { Text(league.scoringLabel.uppercased()) } }
                    if league.seasons.count > 1 { FFPill { Text("\(league.seasons.count) SEASONS") } }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }
}

struct ProfileMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            if let p = app.session?.profile {
                Text("Signed in as \(p.username)")
            }
            Divider()
            Menu {
                ForEach(AppTheme.allCases) { option in
                    Button {
                        Task { await app.setTheme(option) }
                    } label: {
                        if app.theme == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Label(option.label, systemImage: option.systemImage)
                        }
                    }
                }
            } label: {
                Label("Theme: \(app.theme.label)", systemImage: app.theme.systemImage)
            }
            Divider()
            Button("Sign out", role: .destructive) {
                Task { await app.signOut() }
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(FFColor.textPrimary)
        }
    }
}
