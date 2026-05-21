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
// pull-up league chat. Shown once a league is selected.
struct LeagueShellView: View {
    @Environment(AppState.self) private var app
    @State private var showingChat = false

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            NFLHubView()
                .tabItem { Label("NFL", systemImage: "football.fill") }
                .tag(AppTab.nfl)

            LeagueTabView()
                .tabItem { Label("League", systemImage: "trophy.fill") }
                .tag(AppTab.league)
        }
        // Sleeper-style pull-up league chat handle, sitting just above the tab
        // bar on every tab.
        .safeAreaInset(edge: .bottom) {
            LeagueChatHandle { showingChat = true }
        }
        .sheet(isPresented: $showingChat) {
            if let lg = app.selectedLeague {
                NavigationStack { LeagueChatView(league: lg) }
                    .presentationDetents([.large, .medium])
                    .presentationDragIndicator(.visible)
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

// The pull-up handle that opens league chat — a thin bar above the tab bar.
// Tap or swipe up to open. Uses tap + drag gestures (not a Button) so the
// upward-swipe gesture and the tap coexist cleanly.
struct LeagueChatHandle: View {
    let open: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.compact.up")
                .font(.system(size: 15, weight: .bold))
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("League chat")
                .font(.ffMicro)
                .tracking(0.6)
        }
        .foregroundStyle(FFColor.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(FFColor.border).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -24 { open() }
                }
        )
    }
}

#Preview {
    ContentView().environment(AppState.preview)
}
