import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(AppState.self) private var app

    init() {
        // Nav bar: use dynamic UIColors that resolve to dark or light per the
        // current trait collection. SwiftUI's parent preferredColorScheme
        // override flips the trait so these surfaces follow along automatically.
        let bgDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1)
                : UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        }
        let titleDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.91, green: 0.92, blue: 0.95, alpha: 1)
                : UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1)
        }

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
        .sheet(item: $app.presentedTeamAbbr.asIdentifiable) { id in
            TeamProfileLoaderView(abbr: id.id)
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

#Preview {
    ContentView().environment(AppState.preview)
}
