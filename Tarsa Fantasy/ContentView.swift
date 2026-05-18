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
            } else {
                mainTabs
            }
        }
        .preferredColorScheme(app.theme.preferredColorScheme)
        .tint(FFColor.accent)
    }

    private var mainTabs: some View {
        @Bindable var app = app
        return TabView(selection: $app.tab) {
            ChatView()
                .tabItem { Label("Chat", systemImage: "message.fill") }
                .tag(AppTab.chat)

            NFLHubView()
                .tabItem { Label("NFL", systemImage: "football.fill") }
                .tag(AppTab.nfl)

            LeaguesView()
                .tabItem { Label("Leagues", systemImage: "trophy.fill") }
                .tag(AppTab.leagues)
        }
        // Pinned to the top edge so it doesn't shift any content. Ignores
        // safe areas so it sits flush against the navigation bar's bottom
        // border on every tab.
        .overlay(alignment: .top) {
            TopRefreshIndicator(isActive: app.isRefreshingSeason)
        }
        .overlay {
            if let error = app.bootstrapError {
                bootstrapErrorOverlay(error)
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

#Preview {
    ContentView().environment(AppState.preview)
}
