import SwiftUI

// Keeper-lite: pre-draft sheet where an owner (or the commish, via their own
// team) picks up to League.keeperCount players from the roster to carry
// through the draft. Saves through the set_keepers RPC, which validates
// count / roster membership / draft-not-started server-side.
struct KeeperSelectionSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let team: FantasyTeam
    var onSaved: ((League?) -> Void)? = nil

    @State private var selected: Set<String> = []
    @State private var saving: Bool = false
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if let error {
                        Text(error)
                            .font(.ffCaption).foregroundStyle(FFColor.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, FFSpace.l)
                            .padding(.bottom, FFSpace.s)
                    }
                    rosterList
                }
            }
            .navigationTitle("Keepers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving || selected.count > league.keeperCount)
                    .foregroundStyle(FFColor.accent)
                }
            }
            .onAppear { selected = Set(team.keepers) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(selected.count)/\(league.keeperCount) KEEPERS").ffEyebrow()
            Text("Kept players stay on your roster through the draft and can't be drafted by anyone. Everyone else re-enters the pool when the draft starts. You can change this until the draft goes live.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
    }

    private var rosterList: some View {
        let players = app.players(season: league.season)
        return List(team.roster, id: \.self) { pid in
            Button {
                toggle(pid)
            } label: {
                HStack(spacing: FFSpace.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(players[pid]?.name ?? pid)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                        Text(playerMeta(players[pid]))
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    Spacer()
                    Image(systemName: selected.contains(pid) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(pid) ? FFColor.accent : FFColor.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(FFColor.bg)
            .listRowSeparatorTint(FFColor.border)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func playerMeta(_ p: Player?) -> String {
        guard let p else { return "—" }
        let team = p.team.isEmpty ? "FA" : p.team
        return "\(p.position.uppercased()) · \(team)"
    }

    private func toggle(_ pid: String) {
        if selected.contains(pid) {
            selected.remove(pid)
        } else if selected.count < league.keeperCount {
            selected.insert(pid)
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            // Keep roster order for a stable display everywhere else.
            let ordered = team.roster.filter { selected.contains($0) }
            let updated = try await app.setKeepers(
                leagueID: league.id, teamID: team.id, playerIDs: ordered
            )
            onSaved?(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
