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
        for t in league.teams where t.id != team.id { s.formUnion(t.roster) }
        return s
    }

    private var candidates: [PlayerSummary] {
        Fantasy.search(
            players: Fantasy.playersFor(league: league, snapshot: app.players(season: league.season)),
            query: query,
            position: position,
            scoring: league.scoring,
            limit: 300
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar
                    ChipRow(items: Position.allCases, selection: $position) { Text($0.label) }
                        .padding(.vertical, FFSpace.s)
                    if let error {
                        Text(error)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, FFSpace.l)
                    }
                    list
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search players")
            .navigationTitle("Roster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .foregroundStyle(FFColor.accent)
                        .disabled(saving)
                }
            }
        }
    }

    private var headerBar: some View {
        // True when the signed-in user is the commissioner editing a team
        // they don't own — surface a badge so it's obvious this is a commish
        // override, not a regular edit.
        let editingOnBehalf = team.ownerID != app.session?.userID
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: FFSpace.s) {
                    Text(team.name).font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                    if editingOnBehalf {
                        CommissionerBadge(compact: true)
                    }
                }
                Text("\(selected.count) selected").font(.ffCaption).foregroundStyle(FFColor.textSecondary)
            }
            Spacer()
            if !selected.isEmpty {
                Button("Clear") { selected.removeAll() }
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    private var list: some View {
        List {
            ForEach(candidates) { row in
                let taken = rosteredElsewhere.contains(row.id) && !selected.contains(row.id)
                Button {
                    toggle(row.id)
                } label: {
                    candidateRow(row, taken: taken)
                }
                .buttonStyle(.plain)
                .disabled(taken)
                .listRowBackground(FFColor.bg)
                .listRowSeparatorTint(FFColor.border)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(FFColor.bg)
        .prefetchAvatars(urls: candidates.map(\.headshotURL))
    }

    private func candidateRow(_ row: PlayerSummary, taken: Bool) -> some View {
        let isSelected = selected.contains(row.id)
        return HStack(spacing: FFSpace.m) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? FFColor.accent : FFColor.textTertiary)
            PlayerAvatar(url: row.headshotURL, fallback: row.name.initialsFromName, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.ffBody)
                    .foregroundStyle(taken ? FFColor.textTertiary : FFColor.textPrimary)
                HStack(spacing: 6) {
                    PositionPill(position: row.position)
                    Text(row.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    if taken {
                        Text("• on another team")
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.warning)
                    }
                }
            }
            Spacer()
            Text(row.points.fpString)
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            var ordered: [String] = team.roster.filter { selected.contains($0) }
            for id in selected where !ordered.contains(id) { ordered.append(id) }
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
