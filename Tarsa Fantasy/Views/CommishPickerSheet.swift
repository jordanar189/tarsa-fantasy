import SwiftUI

// Pick-on-behalf sheet for the commissioner. Used in the Testing
// Environment to make a bot's selection manually (and also in real leagues
// for managing absent owners). Reuses the same search + filter UI as the
// draft room players list; tapping a row picks for the target team and
// dismisses.
struct CommishPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let team: FantasyTeam
    let pickedPlayerIDs: Set<String>
    let onPick: (PlayerSummary) -> Void

    @State private var query: String = ""
    @State private var position: Position = .all
    @State private var adp: [String: Double] = [:]

    var body: some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let rows = Fantasy.search(
            players: players, query: query, position: position,
            scoring: league.scoring, limit: 0
        ).filter { !pickedPlayerIDs.contains($0.id) }

        return NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    ChipRow(items: Position.allCases, selection: $position) { Text($0.label) }
                        .padding(.vertical, FFSpace.s)
                    if rows.isEmpty {
                        Spacer()
                        Text("No players match.")
                            .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                        Spacer()
                    } else {
                        List(rows.prefix(200), id: \.id) { row in
                            Button {
                                onPick(row)
                                dismiss()
                            } label: {
                                playerRow(row)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(FFColor.bg)
                            .listRowSeparatorTint(FFColor.border)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .prefetchAvatars(urls: Array(rows.prefix(200)).map(\.headshotURL))
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search players")
            .task(id: league.id) {
                adp = league.isTest
                    ? await app.adpForSimulation(season: league.season, scoring: league.scoring)
                    : await app.adp(season: league.season, scoring: league.scoring)
            }
            .navigationTitle("Pick for \(team.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Auto") {
                        if let pid = autoSuggestion(players: players),
                           let summary = rows.first(where: { $0.id == pid }) {
                            onPick(summary)
                            dismiss()
                        }
                    }
                    .foregroundStyle(FFColor.accent)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: FFSpace.s) {
            CommissionerBadge(compact: true)
            Text("Picking for \(team.name)")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
            Spacer()
            Text("\(team.roster.count) players")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textTertiary)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    private func playerRow(_ row: PlayerSummary) -> some View {
        HStack(spacing: FFSpace.m) {
            PlayerAvatar(url: row.headshotURL, fallback: row.name.initialsFromName, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    PositionPill(position: row.position)
                    Text(row.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
            Spacer()
            Text(row.points.fpString)
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.textSecondary)
        }
        .padding(.vertical, 4)
    }

    // "Auto" toolbar suggests the strategy-driven best available so the
    // commish can one-tap fill on the bot's behalf.
    private func autoSuggestion(players: [String: Player]) -> String? {
        Fantasy.bestAutoPickPlayerID(
            team: team, players: players,
            pickedPlayerIDs: pickedPlayerIDs,
            config: league.rosterConfig, scoring: league.scoring, adp: adp
        )
    }
}
