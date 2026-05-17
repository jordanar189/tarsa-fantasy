import SwiftUI

struct LeaguesView: View {
    @Environment(AppState.self) private var app
    @State private var showingCreate = false
    @State private var showingJoin = false
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Leagues")
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                SeasonPickerToolbar()
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
            .navigationDestination(for: String.self) { id in
                LeagueDetailView(leagueID: id)
            }
            .sheet(isPresented: $showingCreate) { CreateLeagueView() }
            .sheet(isPresented: $showingJoin) {
                JoinLeagueView { id in navPath.append(id) }
            }
            .task { await app.reloadLeagues() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.leagueSummaries.isEmpty {
            empty
        } else {
            list
        }
    }

    private var empty: some View {
        VStack(spacing: FFSpace.xxl) {
            Spacer()
            VStack(spacing: FFSpace.s) {
                Image(systemName: "trophy")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(FFColor.textTertiary)
                Text("No leagues yet").font(.ffTitle).foregroundStyle(FFColor.textPrimary)
                Text("Create one, or join with a code.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
            }
            VStack(spacing: FFSpace.s) {
                Button("Create a league") { showingCreate = true }
                    .ffPrimaryButton()
                Button("Join with code") { showingJoin = true }
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
                actionRow(icon: "person.badge.plus", title: "Join with code", subtitle: "Claim a team in an existing league") {
                    showingJoin = true
                }

                HStack {
                    Text("Your leagues").ffEyebrow()
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.top, FFSpace.s)

                ForEach(app.leagueSummaries) { lg in
                    NavigationLink(value: lg.id) {
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
            .padding(FFSpace.l)
        }
    }

    private func actionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FFSpace.l) {
                ZStack {
                    Circle().fill(FFColor.accentSoft)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FFColor.accent)
                }
                .frame(width: 40, height: 40)

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
                    FFPill { Text(String(summary.season)) }
                    FFPill { Text(summary.scoring.label.uppercased()) }
                    FFPill { Text("\(summary.teamCount) TEAMS") }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if !summary.joinCode.isEmpty {
                    Text("CODE").ffEyebrow(color: FFColor.textTertiary)
                    Text(summary.joinCode)
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                }
            }
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
