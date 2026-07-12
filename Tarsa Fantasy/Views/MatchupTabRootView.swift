import SwiftUI

// Matchup tab root: hosts MatchupTabView (born as a screen pushed from the
// Lineup tab, which keeps that push path) in its own NavigationStack.
// MatchupTabView already carries its own title, league switcher, and
// no-league/spectator fallbacks, so this stays a thin shell. The league-wide
// scoreboard is a drill row inside the matchup scroll (see
// MatchupTabView.scoreboardLink) rather than an inline embed — the screen is
// a self-contained ScrollView with its own week picker, and the reskin PR
// decides the final composition.
struct MatchupTabRootView: View {
    var body: some View {
        NavigationStack {
            MatchupTabView()
        }
    }
}

// Full league scoreboard as a pushed screen: the shared ScoreboardSection
// plus the standard tap-a-team roster popup.
struct LeagueScoreboardScreen: View {
    let league: League

    @State private var viewingTeam: FantasyTeam? = nil

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: FFSpace.l) {
                    ScoreboardSection(league: league) { viewingTeam = $0 }
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.s)
                .padding(.bottom, 80)
            }
        }
        .navigationTitle("Scoreboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .sheet(item: $viewingTeam) { team in
            TeamRosterSheet(league: league, team: team)
        }
    }
}
