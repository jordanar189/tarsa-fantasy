import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    init() {
        // Tab bar + nav bar: use dynamic UIColors that resolve to dark or
        // light per the current trait collection. SwiftUI's parent
        // preferredColorScheme override flips the trait so these surfaces
        // follow along automatically.
        let bgDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1)
                : UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        }
        let borderDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.14, green: 0.17, blue: 0.24, alpha: 1)
                : UIColor(red: 0.88, green: 0.90, blue: 0.93, alpha: 1)
        }
        let titleDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.91, green: 0.92, blue: 0.95, alpha: 1)
                : UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1)
        }

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = bgDynamic
        tabAppearance.shadowColor = borderDynamic
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = bgDynamic
        navAppearance.shadowColor = .clear
        navAppearance.titleTextAttributes = [.foregroundColor: titleDynamic]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: titleDynamic]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
    }

    var body: some View {
        @Bindable var app = app
        Group {
            if app.session == nil {
                AuthGateView()
            } else if app.selectedLeagueID == nil {
                // No league in focus → the overview/landing screen, where you
                // pick, create, or join a league (and reach DMs).
                LeagueOverviewView()
            } else {
                mainTabs
            }
        }
        .preferredColorScheme(app.theme.preferredColorScheme)
        .tint(FFColor.accent)
        .sheet(item: $app.presentedPlayerID.asIdentifiable) { id in
            PlayerDetailView(playerID: id.id)
                .presentationDetents([.large])
        }
    }

    private var mainTabs: some View {
        LeagueShellView()
            // Pinned to the top edge so it doesn't shift any content.
            .overlay(alignment: .top) {
                TopRefreshIndicator(isActive: app.isRefreshingSeason)
            }
            .overlay {
                if let error = app.bootstrapError {
                    bootstrapErrorOverlay(error)
                }
            }
            // App-wide feedback button, shown only to testers/admins.
            .overlay {
                if app.canGiveFeedback {
                    FeedbackButton()
                }
            }
    }

    private func bootstrapErrorOverlay(_ error: String) -> some View {
        VStack(spacing: FFSpace.m) {
            FFBrandMark(size: .small)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(FFColor.warning)
            Text("Couldn't load NFL data")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Text(error)
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, FFSpace.l)
            Button("Retry") {
                Task { await app.bootstrap(force: true) }
            }
            .ffPrimaryButton()
            .padding(.horizontal, FFSpace.xl)
        }
        .padding(FFSpace.xxl)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.l))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.l)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
        .padding(40)
    }
}

// The league-focused experience: NFL + League tabs with a Sleeper-style
// pull-up league chat that peeks above the tab bar.
struct LeagueShellView: View {
    @Environment(AppState.self) private var app
    @State private var showingChat = false

    // Standard iPhone tab-bar height; lifts the chat peek so it sits just
    // above the tab bar instead of covering it.
    private let tabBarHeight: CGFloat = 49

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .bottom) {
            TabView(selection: $app.tab) {
                NFLHubView()
                    .tabItem { Label("NFL", systemImage: "football.fill") }
                    .tag(AppTab.nfl)

                LeagueTabView()
                    .tabItem { Label("League", systemImage: "trophy.fill") }
                    .tag(AppTab.league)

                LineupTabView()
                    .tabItem { Label("Lineup", systemImage: "list.bullet.rectangle.portrait") }
                    .tag(AppTab.lineup)

                MatchupTabView()
                    .tabItem { Label("Matchup", systemImage: "person.2.fill") }
                    .tag(AppTab.matchup)
            }
            LeagueChatPeek { showingChat = true }
                .padding(.bottom, tabBarHeight)
        }
        .sheet(isPresented: $showingChat) {
            if let lg = app.selectedLeague {
                VStack(spacing: 0) {
                    LeagueChatTopBar(onClose: { showingChat = false })
                    Divider().background(FFColor.border)
                    LeagueChatView(league: lg)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
        }
    }
}

// Hosts the selected league's detail screen as a tab root. The league switcher
// bubble lives at the top of LeagueDetailView's content.
struct LeagueTabView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            if let id = app.selectedLeagueID {
                LeagueDetailView(leagueID: id)
            } else {
                Color.clear
            }
        }
    }
}

// The shared "top of the chat page": a grabber + title row. Used both as the
// peek (above the tab bar) and as the header of the expanded chat sheet, so
// pulling the peek up reads as the same page rising. `onClose` is nil for the
// peek and set for the sheet (collapse button).
struct LeagueChatTopBar: View {
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(FFColor.borderStrong)
                .frame(width: 38, height: 5)
                .padding(.top, 8)
            HStack(spacing: FFSpace.s) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FFColor.accent)
                Text("League chat")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .background(FFColor.surface)
    }
}

// The peek shown above the tab bar — the top of the chat page poking up over
// the bottom. Looks identical to the expanded sheet's header. Tap or swipe up
// to open the full chat.
struct LeagueChatPeek: View {
    let open: () -> Void

    private var topCorners: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 16
        )
    }

    var body: some View {
        LeagueChatTopBar()
            .clipShape(topCorners)
            .overlay(topCorners.strokeBorder(FFColor.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: -3)
            .contentShape(Rectangle())
            .onTapGesture { open() }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        if value.translation.height < -20 { open() }
                    }
            )
    }
}

#Preview {
    ContentView().environment(AppState.preview)
}
