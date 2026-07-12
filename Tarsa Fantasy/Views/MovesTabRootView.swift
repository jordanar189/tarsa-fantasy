import SwiftUI

// Moves tab root: waivers, trades, and the transaction log for the selected
// league. Thin shell over the existing WaiversView section — which is still
// hosted by LeagueDetailView's Manage segment for the legacy push path.
struct MovesTabRootView: View {
    @Environment(AppState.self) private var app

    private var league: League? { app.selectedLeague }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Moves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .leagueSwitcher()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let league {
            ScrollView {
                WaiversView(league: league) { app.selectedLeague = $0 }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    // Clear the tab bar + collapsed chat peek, matching the
                    // other tab roots.
                    .padding(.bottom, 80)
            }
        } else {
            Spacer()
        }
    }
}
