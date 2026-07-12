import SwiftUI

// Top-level "NFL" tab: Game Center, Players, Teams, Trending, and News
// sub-tabs behind one segmented picker.
struct NFLHubView: View {
    enum SubTab: String, CaseIterable, Identifiable, Hashable {
        case games  = "Game Center"
        case players = "Players"
        case teams   = "Teams"
        case trending = "Trending"
        case news    = "News"
        var id: String { rawValue }
    }

    @State private var subTab: SubTab = .players

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    SegmentedTabPicker(items: SubTab.allCases, selection: $subTab) {
                        Text($0.rawValue)
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, FFSpace.s)
                    Group {
                        switch subTab {
                        case .games:    GameCenterView()
                        case .players:  PlayersBrowser()
                        case .teams:    TeamsView()
                        case .trending: TrendingView()
                        case .news:     NewsFeedView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                SeasonPickerToolbar()
            }
            .leagueSwitcher()
        }
    }
}
