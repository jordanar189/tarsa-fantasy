import SwiftUI

struct CreateLeagueView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var scoring: Scoring = .ppr
    @State private var season: Int = Calendar.current.component(.year, from: Date())
    @State private var teamCount: Int = 8
    @State private var teamNames: [String] = Self.defaultTeamNames(8)
    @State private var rosterConfig: RosterConfig = .default
    @State private var error: String? = nil
    @State private var saving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("League") {
                    TextField("League name", text: $name)
                    Picker("Season", selection: $season) {
                        ForEach(seasonChoices, id: \.self) { Text(String($0)).tag($0) }
                    }
                    Picker("Scoring", selection: $scoring) {
                        ForEach(Scoring.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Teams") {
                    Stepper(value: $teamCount, in: 2...16) {
                        Text("\(teamCount) teams")
                    }
                    .onChange(of: teamCount) { _, new in
                        if new > teamNames.count {
                            teamNames.append(contentsOf: Self.defaultTeamNames(new).suffix(new - teamNames.count))
                        } else {
                            teamNames = Array(teamNames.prefix(new))
                        }
                    }
                    ForEach(teamNames.indices, id: \.self) { i in
                        TextField("Team \(i + 1)", text: Binding(
                            get: { teamNames[i] },
                            set: { teamNames[i] = $0 }
                        ))
                    }
                }
                Section {
                    rosterStepper("QB",    value: $rosterConfig.qb,    range: 0...4)
                    rosterStepper("RB",    value: $rosterConfig.rb,    range: 0...6)
                    rosterStepper("WR",    value: $rosterConfig.wr,    range: 0...6)
                    rosterStepper("TE",    value: $rosterConfig.te,    range: 0...4)
                    rosterStepper("FLEX",  value: $rosterConfig.flex,  range: 0...4)
                    rosterStepper("K",     value: $rosterConfig.k,     range: 0...2)
                    rosterStepper("Bench", value: $rosterConfig.bench, range: 0...12)
                } header: {
                    Text("Roster")
                } footer: {
                    Text("\(rosterConfig.starterCount) starters · \(rosterConfig.totalSize) total. FLEX accepts RB / WR / TE.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New League")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { Task { await create() } }
                        .disabled(saving || teamNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count < 2)
                }
            }
            .onAppear {
                if app.seasons.contains(app.selectedSeason) {
                    season = app.selectedSeason
                } else if let first = app.seasons.first {
                    season = first
                }
            }
        }
    }

    private var seasonChoices: [Int] {
        app.seasons.isEmpty
            ? [Calendar.current.component(.year, from: Date())]
            : app.seasons
    }

    private func create() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await app.createLeague(
                name: name,
                season: season,
                scoring: scoring,
                teamNames: teamNames,
                rosterConfig: rosterConfig
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rosterStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private static func defaultTeamNames(_ n: Int) -> [String] {
        (1...max(n, 2)).map { "Team \($0)" }
    }
}
