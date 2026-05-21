import SwiftUI

struct CreateLeagueView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum LeagueType: String, CaseIterable, Identifiable {
        case standard, simulation
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard:   return "Standard"
            case .simulation: return "Simulation"
            }
        }
    }

    @State private var leagueType: LeagueType = .standard
    @State private var name: String = ""
    @State private var scoring: Scoring = .ppr
    @State private var season: Int = Calendar.current.component(.year, from: Date())
    @State private var yourTeamName: String = "Your Team"
    @State private var otherCount: Int = 7
    @State private var otherTeamNames: [String] = Self.defaultOtherNames(7)
    @State private var rosterConfig: RosterConfig = .default
    @State private var simDraftMode: AppState.SimulationDraftMode = .preDrafted
    @State private var simBotCount: Int = 7
    @State private var regularSeasonWeeks: Int = 14
    @State private var playoffTeams: Int = 6
    @State private var divisionsEnabled: Bool = false
    @State private var divisionCount: Int = 2
    @State private var error: String? = nil
    @State private var saving: Bool = false

    private static let divisionDefaults = ["East", "West", "North", "South"]
    private var teamCount: Int { 1 + otherCount }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.xxl) {
                        section("Type",
                                footer: leagueType == .simulation
                                    ? "A solo league against bot teams. You control every team behind the scenes, can advance through weeks, run bot moves, and reset the simulation at any point."
                                    : "A normal league. Other slots open for friends to claim with an invite link.") {
                            picker("League type", selection: $leagueType, choices: LeagueType.allCases) { $0.label }
                        }

                        section("League") {
                            field("League name") {
                                TextField("", text: $name, prompt: placeholder(leagueType == .simulation ? "e.g. My Simulation" : "e.g. Sunday Crew"))
                            }
                            picker("Season", selection: $season, choices: seasonChoices) { String($0) }
                            picker("Scoring", selection: $scoring, choices: Scoring.allCases) { $0.label }
                        }

                        section("Your team",
                                footer: leagueType == .simulation
                                    ? "Every other team is a bot you control."
                                    : "You'll automatically own this team. Other slots open for friends to claim with an invite link.") {
                            field("Team name") {
                                TextField("", text: $yourTeamName, prompt: placeholder("Your Team"))
                            }
                        }

                        if leagueType == .simulation {
                            section("Simulation",
                                    footer: simDraftMode == .preDrafted
                                        ? "Snake-drafts rosters now and starts at preseason. Best for testing in-season features."
                                        : "Schedules a draft 30 seconds from now with a 20-second pick clock so you can run the draft room.") {
                                picker("Draft mode", selection: $simDraftMode,
                                       choices: [AppState.SimulationDraftMode.preDrafted, .liveDraft]) {
                                    $0 == .preDrafted ? "Pre-drafted" : "Live draft"
                                }
                                stepperRow("Bot teams", value: $simBotCount, range: 1...15) {
                                    "\($0) bot\($0 == 1 ? "" : "s")"
                                }
                            }
                        } else {
                            section("Other teams") {
                                stepperRow("Count", value: $otherCount, range: 1...15) {
                                    "\($0) other team\($0 == 1 ? "" : "s")"
                                }
                                .onChange(of: otherCount) { _, new in
                                    if new > otherTeamNames.count {
                                        otherTeamNames.append(contentsOf:
                                            Self.defaultOtherNames(new).suffix(new - otherTeamNames.count))
                                    } else {
                                        otherTeamNames = Array(otherTeamNames.prefix(new))
                                    }
                                }
                                ForEach(otherTeamNames.indices, id: \.self) { i in
                                    field("Team \(i + 2)") {
                                        TextField("", text: Binding(
                                            get: { otherTeamNames[i] },
                                            set: { otherTeamNames[i] = $0 }
                                        ), prompt: placeholder("Team \(i + 2)"))
                                    }
                                }
                            }
                        }

                        section("Roster",
                                footer: "\(rosterConfig.starterCount) starters · \(rosterConfig.totalSize) total. FLEX accepts RB / WR / TE.") {
                            rosterStepper("QB",    value: $rosterConfig.qb,    range: 0...4)
                            rosterStepper("RB",    value: $rosterConfig.rb,    range: 0...6)
                            rosterStepper("WR",    value: $rosterConfig.wr,    range: 0...6)
                            rosterStepper("TE",    value: $rosterConfig.te,    range: 0...4)
                            rosterStepper("FLEX",  value: $rosterConfig.flex,  range: 0...4)
                            rosterStepper("K",     value: $rosterConfig.k,     range: 0...2)
                            rosterStepper("DEF",   value: $rosterConfig.def,   range: 0...2)
                            rosterStepper("Bench", value: $rosterConfig.bench, range: 0...12)
                            rosterStepper("IR",    value: $rosterConfig.ir,    range: 0...6)
                        }

                        if leagueType == .standard {
                            section("Season format",
                                    footer: playoffSummaryFooter) {
                                stepperRow("Regular season", value: $regularSeasonWeeks, range: 6...15) {
                                    "\($0) weeks"
                                }
                                stepperRow("Playoff teams", value: $playoffTeams, range: 0...teamCount) {
                                    $0 == 0 ? "Off" : "\($0) teams"
                                }
                            }

                            section("Divisions",
                                    footer: "Division winners are seeded ahead of wildcards in the playoffs. You can rename divisions and reassign teams later in settings.") {
                                Toggle(isOn: $divisionsEnabled) {
                                    Text("Use divisions").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                                }
                                .tint(FFColor.accent)
                                .padding(.horizontal, FFSpace.l).padding(.vertical, 10)
                                .ffHairlineBottom()
                                if divisionsEnabled {
                                    stepperRow("Divisions", value: $divisionCount,
                                               range: 2...max(2, min(4, teamCount))) {
                                        "\($0) divisions"
                                    }
                                }
                            }
                        }

                        if let error {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, FFSpace.l)
                        }
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.vertical, FFSpace.xxl)
                }
            }
            .navigationTitle("New league")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { Task { await create() } }
                        .foregroundStyle(canCreate ? FFColor.accent : FFColor.textTertiary)
                        .disabled(saving || !canCreate)
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

    private var canCreate: Bool {
        guard !yourTeamName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch leagueType {
        case .standard:
            return otherTeamNames.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        case .simulation:
            return simBotCount >= 1
        }
    }

    private var playoffSummaryFooter: String {
        let teams = min(playoffTeams, teamCount)
        guard teams >= 2 else {
            return "No postseason — final standings after \(regularSeasonWeeks) weeks decide it."
        }
        let rounds = max(1, Int(ceil(log2(Double(teams)))))
        let start = regularSeasonWeeks + 1
        let end = regularSeasonWeeks + rounds
        return "Top \(teams) make the playoffs (weeks \(start)–\(end)). Higher seeds get first-round byes when needed."
    }

    private var seasonChoices: [Int] {
        app.seasons.isEmpty
            ? [Calendar.current.component(.year, from: Date())]
            : app.seasons
    }

    // MARK: - Section builder

    @ViewBuilder
    private func section<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(title).ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                content()
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
            if let footer {
                Text(footer)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                    .padding(.horizontal, FFSpace.s)
            }
        }
    }

    private func placeholder(_ text: String) -> Text {
        Text(text).foregroundColor(FFColor.textTertiary)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            content()
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, 12)
        .ffHairlineBottom()
    }

    @ViewBuilder
    private func picker<Value: Hashable>(
        _ label: String,
        selection: Binding<Value>,
        choices: [Value],
        title: @escaping (Value) -> String
    ) -> some View {
        HStack {
            Text(label).font(.ffBody).foregroundStyle(FFColor.textSecondary)
            Spacer()
            Menu {
                Picker(label, selection: selection) {
                    ForEach(choices, id: \.self) { v in
                        Text(title(v)).tag(v)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title(selection.wrappedValue))
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, 14)
        .ffHairlineBottom()
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, formatter: @escaping (Int) -> String) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label).font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
                Text(formatter(value.wrappedValue))
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textPrimary)
            }
        }
        .tint(FFColor.accent)
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, 10)
        .ffHairlineBottom()
    }

    private func rosterStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
            }
        }
        .tint(FFColor.accent)
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, 10)
        .ffHairlineBottom()
    }

    private func create() async {
        saving = true
        defer { saving = false }
        do {
            let resolvedName = name.trimmingCharacters(in: .whitespaces).isEmpty
                ? (leagueType == .simulation ? "My Simulation" : "My League")
                : name
            switch leagueType {
            case .standard:
                let divisions = divisionsEnabled
                    ? Array(Self.divisionDefaults.prefix(min(divisionCount, 4)))
                    : []
                _ = try await app.createLeague(
                    name: resolvedName, season: season, scoring: scoring,
                    yourTeamName: yourTeamName, otherTeamNames: otherTeamNames,
                    rosterConfig: rosterConfig,
                    regularSeasonWeeks: regularSeasonWeeks,
                    playoffTeams: min(playoffTeams, teamCount),
                    playoffReseed: true,
                    divisionNames: divisions
                )
            case .simulation:
                _ = try await app.createSimulation(
                    name: resolvedName, season: season, scoring: scoring,
                    rosterConfig: rosterConfig,
                    yourTeamName: yourTeamName,
                    mode: simDraftMode,
                    botCount: simBotCount
                )
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func defaultOtherNames(_ n: Int) -> [String] {
        (2...max(n + 1, 2)).map { "Team \($0)" }
    }
}
