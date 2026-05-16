import SwiftUI

struct RosterEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let team: FantasyTeam
    let onSave: (League) -> Void

    @State private var selected: Set<String>
    @State private var query: String = ""
    @State private var position: Position = .all
    @State private var saving: Bool = false
    @State private var error: String? = nil

    init(league: League, team: FantasyTeam, onSave: @escaping (League) -> Void) {
        self.league = league
        self.team = team
        self.onSave = onSave
        _selected = State(initialValue: Set(team.roster))
    }

    private var rosteredElsewhere: Set<String> {
        var s = Set<String>()
        for t in league.teams where t.id != team.id {
            s.formUnion(t.roster)
        }
        return s
    }

    private var candidates: [PlayerSummary] {
        Fantasy.search(
            players: app.players(season: league.season),
            query: query,
            position: position,
            scoring: league.scoring,
            limit: 300
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("\(selected.count) selected").font(.subheadline.bold())
                    Spacer()
                    if !selected.isEmpty {
                        Button("Clear") { selected.removeAll() }
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal).padding(.top, 8)

                ChipRow(items: Position.allCases, selection: $position) {
                    Text($0.label)
                }
                .padding(.vertical, 8)

                if let error {
                    Text(error).foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }

                List(candidates) { row in
                    let taken = rosteredElsewhere.contains(row.id) && !selected.contains(row.id)
                    Button {
                        toggle(row.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(row.id) ? Color.accentColor : Color.secondary)
                            PlayerAvatar(url: row.headshotURL, fallback: row.name.initialsFromName)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.subheadline.bold())
                                HStack(spacing: 6) {
                                    PositionPill(position: row.position)
                                    Text(row.team).font(.caption).foregroundStyle(.secondary)
                                    if taken {
                                        Text("• on another team")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                            }
                            Spacer()
                            Text(row.points.fpString).monospacedDigit()
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(taken)
                }
                .listStyle(.plain)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search players")
            .navigationTitle("Roster — \(team.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) }
        else { selected.insert(id) }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            // Preserve the existing draft order, then append any newly selected ids.
            var ordered: [String] = team.roster.filter { selected.contains($0) }
            for id in selected where !ordered.contains(id) {
                ordered.append(id)
            }
            let updated = try await app.setRoster(
                leagueID: league.id, teamID: team.id, playerIDs: ordered
            )
            onSave(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
