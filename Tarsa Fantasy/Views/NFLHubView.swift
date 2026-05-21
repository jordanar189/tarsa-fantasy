import SwiftUI

// Top-level "NFL" tab. Phase 1 wires up the Players sub-tab (enriched
// list); Game Center / Teams / Trending are placeholders that will be
// filled in phases 2 and 3 of the stats overhaul.
struct NFLHubView: View {
    @Environment(AppState.self) private var app

    enum SubTab: String, CaseIterable, Identifiable, Hashable {
        case games  = "Game Center"
        case players = "Players"
        case teams   = "Teams"
        case trending = "Trending"
        var id: String { rawValue }
    }

    @State private var subTab: SubTab = .players
    @State private var selectedPlayerID: String? = nil

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
                        case .games:    GameCenterView(selectedPlayerID: $selectedPlayerID)
                        case .players:  PlayersBrowser(selectedPlayerID: $selectedPlayerID)
                        case .teams:    TeamsView(selectedPlayerID: $selectedPlayerID)
                        case .trending: TrendingView(selectedPlayerID: $selectedPlayerID)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { LeagueSwitcher() }
                SeasonPickerToolbar()
            }
            .sheet(item: $selectedPlayerID.asIdentifiable) { id in
                PlayerDetailView(playerID: id.id)
                    .presentationDetents([.large])
            }
        }
    }

    private func comingSoon(icon: String, title: String, note: String) -> some View {
        VStack(spacing: FFSpace.m) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text(title).font(.ffTitle).foregroundStyle(FFColor.textPrimary)
            Text(note)
                .font(.ffBody)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, FFSpace.xl)
            Spacer()
        }
    }
}
