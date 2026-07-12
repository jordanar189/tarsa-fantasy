import SwiftUI

// Commissioner-only settings sheet. Four sections:
//   General  – rename league, change scoring
//   Roster   – per-slot counts (shrinking only enforces on future adds)
//   Waivers  – approval toggle, process schedule, priority order
//   Members  – rename teams; "kick" an owner (clears owner_id; team stays)
struct LeagueSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let onSave: (League) -> Void
    var onDelete: (() -> Void)? = nil

    // General
    @State private var leagueName: String
    @State private var scoring: Scoring
    // Roster
    @State private var rosterConfig: RosterConfig
    // Waivers
    @State private var waiverSettings: WaiverSettings
    @State private var priority: [String]
    // Trades
    @State private var tradeSettings: TradeSettings
    @State private var hasTradeDeadline: Bool
    // Playoffs
    @State private var playoffTeams: Int
    @State private var playoffReseed: Bool
    @State private var tiebreaker: TiebreakerMode
    @State private var playoffStartWeek: Int
    @State private var weeksPerRound: Int
    // Custom scoring
    @State private var useCustomScoring: Bool
    @State private var scoringSettings: ScoringSettings
    // Taxi squad
    @State private var taxiEnabled: Bool
    @State private var keeperCount: Int
    @State private var keeperRoundCost: Bool
    @State private var hasKeeperDeadline: Bool
    @State private var keeperDeadline: Date?
    // Divisions
    @State private var divisionsEnabled: Bool
    @State private var divisionNames: [String]
    @State private var teamDivisions: [String: Int]
    // Delete-league flow
    @State private var showingDeletePanel: Bool = false
    @State private var deleteConfirmText: String = ""
    @State private var deleting: Bool = false
    @FocusState private var deleteFieldFocused: Bool
    // Season-completion flow
    @State private var completing: Bool = false
    @State private var rollingOver: Bool = false
    @State private var rolloverSeason: Int = Calendar.current.component(.year, from: Date())
    @State private var confirmingComplete: Bool = false
    @State private var confirmingRetroactive: Bool = false
    // Draft picks
    @State private var generatingPicks: Bool = false
    @State private var pickGenResult: String? = nil
    // Members
    @State private var editingTeamID: String? = nil
    @State private var editingTeamName: String = ""
    @State private var teamToKick: TeamRef? = nil

    @State private var saving: Bool = false
    @State private var error: String? = nil

    struct TeamRef: Identifiable {
        let id: String
        let name: String
    }

    init(league: League,
         onSave: @escaping (League) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.league = league
        self.onSave = onSave
        self.onDelete = onDelete
        _leagueName    = State(initialValue: league.name)
        _scoring       = State(initialValue: league.scoring)
        _rosterConfig  = State(initialValue: league.rosterConfig)
        _waiverSettings = State(initialValue: league.waiverSettings)
        let known = Set(league.waiverPriority)
        let missing = league.teams.map(\.id).filter { !known.contains($0) }
        _priority = State(initialValue: league.waiverPriority + missing)
        _tradeSettings = State(initialValue: league.tradeSettings)
        _hasTradeDeadline = State(initialValue: league.tradeSettings.deadline != nil)
        _playoffTeams = State(initialValue: league.playoffTeams)
        _playoffReseed = State(initialValue: league.playoffReseed)
        _tiebreaker = State(initialValue: league.tiebreaker)
        _playoffStartWeek = State(initialValue: league.playoffStartWeek)
        _weeksPerRound = State(initialValue: league.weeksPerRound)
        _useCustomScoring = State(initialValue: league.scoringSettings != nil)
        _scoringSettings = State(initialValue: league.effectiveScoringSettings)
        _taxiEnabled = State(initialValue: league.rosterConfig.taxi > 0)
        _keeperCount = State(initialValue: league.keeperCount)
        _keeperRoundCost = State(initialValue: league.keeperRoundCost)
        _hasKeeperDeadline = State(initialValue: league.keeperDeadline != nil)
        _keeperDeadline = State(initialValue: league.keeperDeadline)
        _divisionsEnabled = State(initialValue: league.hasDivisions)
        _divisionNames = State(initialValue: league.divisionNames.isEmpty
                               ? ["East", "West"] : league.divisionNames)
        var divs: [String: Int] = [:]
        for t in league.teams { if let d = t.division { divs[t.id] = d } }
        _teamDivisions = State(initialValue: divs)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                Form {
                    inviteSection
                    generalSection
                    rosterSection
                    taxiSection
                    playoffsSection
                    scoringSection
                    divisionsSection
                    waiversSection
                    tradesSection
                    if league.isDynasty || league.keeperCount > 0 {
                        pickAssetsSection
                    }
                    membersSection
                    seasonSection
                    dangerSection
                    if let error {
                        Section {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                        }
                        .listRowBackground(FFColor.surface)
                    }
                }
                .environment(\.editMode, .constant(.active))
                .scrollContentBackground(.hidden)
                .background(FFColor.bg)
            }
            .navigationTitle("League settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if retroactiveChangePending {
                            confirmingRetroactive = true
                        } else {
                            Task { await save() }
                        }
                    }
                    .foregroundStyle(FFColor.accent)
                    .disabled(saving)
                }
            }
            .alert("Rewrite past weeks?", isPresented: $confirmingRetroactive) {
                Button("Cancel", role: .cancel) {}
                Button("Save anyway", role: .destructive) {
                    Task { await save() }
                }
            } message: {
                Text("Games have already been played. Roster-slot and scoring changes apply to every week, including finished ones — past scores, standings, and playoff seeding will be recomputed under the new rules.")
            }
            .alert(item: $teamToKick) { ref in
                Alert(
                    title: Text("Kick \(ref.name)?"),
                    message: Text("The owner is removed from the league. The team stays and can be re-claimed with the join code. The roster is kept."),
                    primaryButton: .destructive(Text("Kick")) {
                        Task { await kick(teamID: ref.id) }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // MARK: - Invite (commish-only — gated by parent presenting this sheet)

    private var inviteSection: some View {
        Section {
            if let url = JoinLink.url(forCode: league.joinCode) {
                ShareLink(
                    item: url,
                    subject: Text("Join \(league.name) on Tarsa Fantasy"),
                    message: Text("Tap to claim a team in \(league.name).")
                ) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share invite link")
                        Spacer()
                    }
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.accent)
                }
            }
            HStack {
                Text("Join code").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
                Text(league.joinCode)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textTertiary)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = league.joinCode
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(FFColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy join code")
            }
        } header: {
            Text("Invite").ffEyebrow()
        } footer: {
            Text("Share the link so friends can tap straight into an open team. The code still works for manual entry.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            HStack {
                Text("Name").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
                TextField("League name", text: $leagueName)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(FFColor.textPrimary)
            }
            Picker("Scoring", selection: $scoring) {
                ForEach(Scoring.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            HStack {
                Text("Season").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
                Text(String(league.season))
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textTertiary)
            }
        } header: {
            Text("General").ffEyebrow()
        } footer: {
            Text("Scoring changes apply retroactively — all past games are scored under the new rule.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    // MARK: - Roster

    private var rosterSection: some View {
        Section {
            rosterStepper("QB",    value: $rosterConfig.qb,    range: 0...4)
            rosterStepper("RB",    value: $rosterConfig.rb,    range: 0...6)
            rosterStepper("WR",    value: $rosterConfig.wr,    range: 0...6)
            rosterStepper("TE",    value: $rosterConfig.te,    range: 0...4)
            rosterStepper("FLEX",  value: $rosterConfig.flex,  range: 0...4)
            rosterStepper("SFLX",  value: $rosterConfig.superflex, range: 0...2)
            rosterStepper("W/R",   value: $rosterConfig.wrFlex,    range: 0...3)
            rosterStepper("W/T",   value: $rosterConfig.recFlex,   range: 0...3)
            rosterStepper("K",     value: $rosterConfig.k,     range: 0...2)
            rosterStepper("DEF",   value: $rosterConfig.def,   range: 0...2)
            rosterStepper("DL",    value: $rosterConfig.dl,    range: 0...4)
            rosterStepper("LB",    value: $rosterConfig.lb,    range: 0...4)
            rosterStepper("DB",    value: $rosterConfig.db,    range: 0...4)
            rosterStepper("IDP",   value: $rosterConfig.idpFlex, range: 0...4)
            rosterStepper("Bench", value: $rosterConfig.bench, range: 0...12)
            rosterStepper("IR",    value: $rosterConfig.ir,    range: 0...6)
            // Keeper-lite: how many players each team carries through the
            // draft. Owners pick theirs in the draft room pre-draft.
            rosterStepper("Keepers", value: $keeperCount,
                          range: 0...max(0, rosterConfig.totalSize - 1))
            if keeperCount > 0 {
                Toggle("Keepers cost draft rounds", isOn: $keeperRoundCost)
                    .tint(FFColor.accent)
                Toggle("Keeper deadline", isOn: $hasKeeperDeadline)
                    .tint(FFColor.accent)
                    .onChange(of: hasKeeperDeadline) { _, on in
                        if on {
                            if keeperDeadline == nil {
                                // Default: a week from today, evening.
                                keeperDeadline = Calendar.current.date(
                                    byAdding: .day, value: 7, to: Date()
                                )
                            }
                        } else {
                            keeperDeadline = nil
                        }
                    }
                if hasKeeperDeadline {
                    DatePicker(
                        "Deadline",
                        selection: Binding(
                            get: { keeperDeadline ?? Date() },
                            set: { keeperDeadline = $0 }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .tint(FFColor.accent)
                }
            }
            HStack {
                Text("Total").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text("\(rosterConfig.starterCount) starters · \(rosterConfig.totalSize) max" +
                     (rosterConfig.ir > 0 ? " · \(rosterConfig.ir) IR" : "") +
                     (rosterConfig.taxi > 0 ? " · \(rosterConfig.taxi) taxi" : ""))
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
            }
            if let warning = rosterWarning() {
                Text(warning)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.warning)
            }
        } header: {
            Text("Roster").ffEyebrow()
        } footer: {
            Text(rosterFooter)
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private var rosterFooter: String {
        var text = "Shrinking the roster is allowed even if a team currently has more players — they'll just be unable to add new ones until they drop."
        if keeperCount > 0 {
            text += keeperRoundCost
                ? " Each keeper consumes the team's pick in the round the player cost last season (one round earlier per consecutive keep; undrafted pickups cost the last round)."
                : " Keepers simply carry through: the draft runs \(keeperCount) fewer round\(keeperCount == 1 ? "" : "s")."
            if hasKeeperDeadline {
                text += " Owners can change keepers until the deadline; you can adjust them any time before the draft."
            }
        }
        return text
    }

    // MARK: - Taxi squad

    private var taxiSection: some View {
        Section {
            Toggle("Taxi squad", isOn: $taxiEnabled)
                .tint(FFColor.accent)
                .onChange(of: taxiEnabled) { _, on in
                    if on && rosterConfig.taxi == 0 { rosterConfig.taxi = 2 }
                }
            if taxiEnabled {
                rosterStepper("Taxi slots", value: $rosterConfig.taxi, range: 1...10)
                Stepper(value: $rosterConfig.taxiMaxExperience, in: 0...5) {
                    HStack {
                        Text("Max experience").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text(taxiExperienceLabel(rosterConfig.taxiMaxExperience))
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
                .tint(FFColor.accent)
            }
        } header: {
            Text("Taxi squad").ffEyebrow()
        } footer: {
            Text(taxiEnabled
                 ? "Managers can stash up to \(rosterConfig.taxi) \(taxiExperienceLabel(rosterConfig.taxiMaxExperience).lowercased()) off the active roster. Taxi players don't score and don't count against the roster limit."
                 : "Off. Turn on to give managers extra slots for developing inexperienced players.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private func taxiExperienceLabel(_ years: Int) -> String {
        years == 0 ? "Rookies only" : "≤ \(years) year\(years == 1 ? "" : "s") experience"
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
    }

    // Roster-slot and scoring edits recompute every week retroactively
    // (standings/scores derive from the current config). Once any rostered
    // player has a recorded game, warn before saving such a change.
    private var retroactiveChangePending: Bool {
        let effectiveConfig: RosterConfig = {
            var cfg = rosterConfig
            cfg.taxi = taxiEnabled ? max(1, cfg.taxi) : 0
            return cfg
        }()
        let rosterChanged = effectiveConfig != league.rosterConfig
        let scoringChanged = scoring != league.scoring
            || (useCustomScoring ? scoringSettings : nil) != league.scoringSettings
        guard rosterChanged || scoringChanged else { return false }
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let rostered = Set(league.teams.flatMap(\.roster))
        return players.values.contains { rostered.contains($0.id) && !$0.games.isEmpty }
    }

    private func rosterWarning() -> String? {
        let newTotal = rosterConfig.totalSize
        let over = league.teams.filter { $0.roster.count > newTotal }
        guard !over.isEmpty else { return nil }
        return "\(over.count) team\(over.count == 1 ? "" : "s") currently exceed the new roster size and won't be able to add until they drop."
    }

    // MARK: - Playoffs

    private var playoffsSection: some View {
        Section {
            Stepper(value: $playoffTeams, in: 0...league.teams.count) {
                HStack {
                    Text("Playoff teams").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    Text(playoffTeams == 0 ? "Off" : "\(playoffTeams)")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                }
            }
            .tint(FFColor.accent)
            // Tiebreaker among equal-win% teams; drives standings + seeding.
            Picker(selection: $tiebreaker) {
                ForEach(TiebreakerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                Text("Tiebreaker").font(.ffBody).foregroundStyle(FFColor.textPrimary)
            }
            .pickerStyle(.menu)
            .tint(FFColor.accent)
            if playoffTeams >= 2 {
                Toggle("Re-seed each round", isOn: $playoffReseed)
                    .tint(FFColor.accent)
                Stepper(value: $playoffStartWeek, in: playoffStartRange) {
                    HStack {
                        Text("Start week").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text("Week \(playoffStartWeek)").font(.ffStatSmall).foregroundStyle(FFColor.accent)
                    }
                }
                .tint(FFColor.accent)
                Picker(selection: $weeksPerRound) {
                    Text("1 week").tag(1)
                    Text("2 weeks").tag(2)
                } label: {
                    Text("Weeks per round").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                }
                .pickerStyle(.menu)
                .tint(FFColor.accent)
                HStack {
                    Text("Postseason").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    Spacer()
                    Text(playoffSummary)
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
        } header: {
            Text("Playoffs").ffEyebrow()
        } footer: {
            Text(playoffsFooter)
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
        // Keep the start week valid as the field size / round length change the
        // latest week the bracket can still finish by Week 18.
        .onAppear { clampPlayoffStart() }
        .onChange(of: weeksPerRound) { _, _ in clampPlayoffStart() }
        .onChange(of: playoffTeams) { _, _ in clampPlayoffStart() }
    }

    // Rounds needed for the current field, and the total weeks they span.
    private var playoffSpan: Int {
        guard playoffTeams >= 2 else { return 0 }
        let rounds = max(1, Int(ceil(log2(Double(playoffTeams)))))
        return rounds * max(1, weeksPerRound)
    }
    // Latest start so the championship still ends by Week 18; floor keeps ≥6
    // regular-season weeks when the span allows.
    private var maxPlayoffStartWeek: Int { max(2, League.maxSeasonWeek - playoffSpan + 1) }
    private var minPlayoffStartWeek: Int { min(7, maxPlayoffStartWeek) }
    private var playoffStartRange: ClosedRange<Int> { minPlayoffStartWeek...maxPlayoffStartWeek }
    private var playoffEndWeek: Int { playoffStartWeek + playoffSpan - 1 }

    private func clampPlayoffStart() {
        playoffStartWeek = min(max(playoffStartWeek, minPlayoffStartWeek), maxPlayoffStartWeek)
    }

    private var playoffSummary: String {
        guard playoffTeams >= 2 else { return "Off" }
        return "Weeks \(playoffStartWeek)–\(playoffEndWeek)"
    }

    private var playoffsFooter: String {
        guard playoffTeams >= 2 else {
            return "No postseason — final standings decide it."
        }
        return "Regular season runs Weeks 1–\(playoffStartWeek - 1); playoffs Weeks "
            + "\(playoffStartWeek)–\(playoffEndWeek) (championship Week \(playoffEndWeek)). "
            + "Latest start that finishes by Week \(League.maxSeasonWeek) is Week \(maxPlayoffStartWeek). "
            + "Changing the start week reshuffles the remaining schedule, so set it before games are played."
    }

    // MARK: - Scoring (custom per-stat)

    private var scoringSection: some View {
        Section {
            Toggle("Custom scoring", isOn: $useCustomScoring)
                .tint(FFColor.accent)
            if useCustomScoring {
                scoringStepper("Pass yds / point", value: $scoringSettings.passingYardsPerPoint, range: 5...50, step: 5)
                scoringStepper("Pass TD",          value: $scoringSettings.passingTD,            range: 0...10, step: 1)
                scoringStepper("Interception",     value: $scoringSettings.interception,         range: -5...0, step: 1)
                scoringStepper("Rush yds / point", value: $scoringSettings.rushingYardsPerPoint, range: 5...20, step: 1)
                scoringStepper("Rush TD",          value: $scoringSettings.rushingTD,            range: 0...10, step: 1)
                scoringStepper("Rec yds / point",  value: $scoringSettings.receivingYardsPerPoint, range: 5...20, step: 1)
                scoringStepper("Rec TD",           value: $scoringSettings.receivingTD,          range: 0...10, step: 1)
                scoringStepper("Per reception",    value: $scoringSettings.reception,            range: 0...2, step: 0.5)
                scoringStepper("Fumble lost",      value: $scoringSettings.fumbleLost,           range: -5...0, step: 1)

                Text("Kicking").ffEyebrow()
                scoringStepper("FG 0–39",          value: $scoringSettings.fgUnder40,            range: 0...10, step: 1)
                scoringStepper("FG 40–49",         value: $scoringSettings.fg40to49,            range: 0...10, step: 1)
                scoringStepper("FG 50+",           value: $scoringSettings.fg50plus,            range: 0...10, step: 1)
                scoringStepper("Extra point",      value: $scoringSettings.patMade,             range: 0...5, step: 1)
                scoringStepper("Missed FG",        value: $scoringSettings.fgMissed,            range: -5...0, step: 1)
                scoringStepper("Missed PAT",       value: $scoringSettings.patMissed,           range: -5...0, step: 1)

                Text("Defense (DST)").ffEyebrow()
                scoringStepper("Sack",             value: $scoringSettings.defSack,             range: 0...5, step: 0.5)
                scoringStepper("Interception",     value: $scoringSettings.defInterception,     range: 0...10, step: 1)
                scoringStepper("Fumble recovery",  value: $scoringSettings.defFumbleRecovery,   range: 0...10, step: 1)
                scoringStepper("Defensive TD",     value: $scoringSettings.defTouchdown,        range: 0...10, step: 1)
                scoringStepper("Safety",           value: $scoringSettings.defSafety,           range: 0...10, step: 1)

                Text("DST points allowed").ffEyebrow()
                scoringStepper("Shutout",          value: $scoringSettings.paShutout,           range: 0...15, step: 1)
                scoringStepper("1–6 allowed",      value: $scoringSettings.paUnder7,            range: 0...12, step: 1)
                scoringStepper("7–13 allowed",     value: $scoringSettings.paUnder14,           range: 0...10, step: 1)
                scoringStepper("14–20 allowed",    value: $scoringSettings.paUnder21,           range: -3...6, step: 1)
                scoringStepper("21–27 allowed",    value: $scoringSettings.paUnder28,           range: -4...4, step: 1)
                scoringStepper("28–34 allowed",    value: $scoringSettings.paUnder35,           range: -6...2, step: 1)
                scoringStepper("35+ allowed",      value: $scoringSettings.pa35Plus,            range: -8...0, step: 1)

                Text("IDP").ffEyebrow()
                scoringStepper("Solo tackle",      value: $scoringSettings.idpSoloTackle,     range: 0...4, step: 0.25)
                scoringStepper("Assisted tackle",  value: $scoringSettings.idpAssistTackle,   range: 0...2, step: 0.25)
                scoringStepper("Tackle for loss",  value: $scoringSettings.idpTackleForLoss,  range: 0...6, step: 0.5)
                scoringStepper("Sack",             value: $scoringSettings.idpSack,           range: 0...10, step: 0.5)
                scoringStepper("QB hit",           value: $scoringSettings.idpQbHit,          range: 0...4, step: 0.5)
                scoringStepper("Interception",     value: $scoringSettings.idpInterception,   range: 0...10, step: 1)
                scoringStepper("Pass defended",    value: $scoringSettings.idpPassDefended,   range: 0...5, step: 0.5)
                scoringStepper("Forced fumble",    value: $scoringSettings.idpForcedFumble,   range: 0...10, step: 1)
                scoringStepper("Fumble recovery",  value: $scoringSettings.idpFumbleRecovery, range: 0...10, step: 1)
                scoringStepper("Defensive TD",     value: $scoringSettings.idpTouchdown,      range: 0...10, step: 1)
                scoringStepper("Safety",           value: $scoringSettings.idpSafety,         range: 0...10, step: 1)
            }
        } header: {
            Text("Scoring").ffEyebrow()
        } footer: {
            Text(useCustomScoring
                 ? "Custom weights are applied to every game retroactively, computed from raw stat lines. Any player scores for any action they record."
                 : "Using the \(scoring.label) preset. Turn on custom scoring to set per-stat values.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private func scoringStepper(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text(value.wrappedValue.statString)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
            }
        }
        .tint(FFColor.accent)
    }

    // MARK: - Divisions

    private var divisionsSection: some View {
        Section {
            Toggle("Divisions", isOn: $divisionsEnabled)
                .tint(FFColor.accent)
            if divisionsEnabled {
                Stepper(value: divisionCountBinding, in: 2...max(2, min(4, league.teams.count))) {
                    HStack {
                        Text("Divisions").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text("\(divisionNames.count)")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
                .tint(FFColor.accent)
                ForEach(divisionNames.indices, id: \.self) { i in
                    HStack {
                        Text("Name \(i + 1)").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                        Spacer()
                        TextField("Division \(i + 1)", text: Binding(
                            get: { divisionNames[i] },
                            set: { divisionNames[i] = $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(FFColor.textPrimary)
                    }
                }
                ForEach(league.teams) { team in
                    Picker(team.name, selection: divisionBinding(for: team.id)) {
                        ForEach(divisionNames.indices, id: \.self) { i in
                            Text(divisionNames[i]).tag(i)
                        }
                    }
                }
            }
        } header: {
            Text("Divisions").ffEyebrow()
        } footer: {
            Text("Division winners are seeded ahead of wildcards in the playoff bracket.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private var divisionCountBinding: Binding<Int> {
        Binding(
            get: { divisionNames.count },
            set: { newCount in
                if newCount > divisionNames.count {
                    for i in divisionNames.count..<newCount { divisionNames.append("Division \(i + 1)") }
                } else if newCount < divisionNames.count {
                    divisionNames = Array(divisionNames.prefix(newCount))
                    // Pull any team assigned to a removed division back to 0.
                    for (tid, d) in teamDivisions where d >= newCount { teamDivisions[tid] = 0 }
                }
            }
        )
    }

    private func divisionBinding(for teamID: String) -> Binding<Int> {
        Binding(
            get: { teamDivisions[teamID] ?? 0 },
            set: { teamDivisions[teamID] = $0 }
        )
    }

    // MARK: - Waivers

    private var waiversSection: some View {
        Section {
            Picker("Claim resolution", selection: $waiverSettings.mode) {
                ForEach(WaiverMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            if waiverSettings.mode == .faab {
                Stepper(value: $waiverSettings.faabBudget, in: 10...1000, step: 10) {
                    HStack {
                        Text("FAAB budget").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text("$\(waiverSettings.faabBudget)")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
            }
            Toggle("Commissioner approval", isOn: $waiverSettings.commissionerApproval)
                .tint(FFColor.accent)
            Picker("Process day", selection: $waiverSettings.processDay) {
                ForEach(0..<7, id: \.self) { d in
                    Text(WaiverSettings(processDay: d, processHour: 0, periodHours: 0,
                                        commissionerApproval: false).processDayLabel).tag(d)
                }
            }
            Stepper(value: $waiverSettings.processHour, in: 0...23) {
                HStack {
                    Text("Process hour (UTC)").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    Text(String(format: "%02d:00", waiverSettings.processHour))
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                }
            }
            Stepper(value: $waiverSettings.periodHours, in: 1...168) {
                HStack {
                    Text("Waiver period").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    Text("\(waiverSettings.periodHours)h")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                }
            }
            ForEach(Array(priority.enumerated()), id: \.element) { idx, teamID in
                HStack {
                    Text("#\(idx + 1)")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                        .frame(width: 32, alignment: .leading)
                    Text(teamName(teamID))
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            .onMove { from, to in priority.move(fromOffsets: from, toOffset: to) }
        } header: {
            Text("Waivers").ffEyebrow()
        } footer: {
            Text(waiverSettings.mode == .faab
                ? "FAAB: every claim carries a blind bid from each team's season budget; the highest bid wins (ties go to the better waiver position). When approval is on, every add/drop and waiver claim by another manager waits for you in Activity."
                : "When approval is on, every add/drop and waiver claim by another manager waits for you in Activity. Priority #1 wins contested claims first; winners roll to the back automatically.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    // MARK: - Trades

    private var tradesSection: some View {
        Section {
            Picker("Approval", selection: $tradeSettings.approval) {
                ForEach(TradeApprovalMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Toggle("Trade deadline", isOn: $hasTradeDeadline)
                .tint(FFColor.accent)
                .onChange(of: hasTradeDeadline) { _, on in
                    if on {
                        // Default deadline: ~10 weeks from today.
                        if tradeSettings.deadline == nil {
                            tradeSettings.deadline = Calendar.current.date(
                                byAdding: .day, value: 70, to: Date()
                            )
                        }
                    } else {
                        tradeSettings.deadline = nil
                    }
                }
            if hasTradeDeadline {
                DatePicker(
                    "Deadline date",
                    selection: Binding(
                        get: { tradeSettings.deadline ?? Date() },
                        set: { tradeSettings.deadline = $0 }
                    ),
                    in: Date()...,
                    displayedComponents: [.date]
                )
                .tint(FFColor.accent)
            }
            if tradeSettings.approval == .leagueVote {
                Stepper(value: $tradeSettings.voteHours, in: 1...168) {
                    HStack {
                        Text("Vote window").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text("\(tradeSettings.voteHours)h")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
            }
        } header: {
            Text("Trades").ffEyebrow()
        } footer: {
            Text(tradesFooter)
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private var tradesFooter: String {
        switch tradeSettings.approval {
        case .none:
            return "Accepted trades execute as soon as all included players are unlocked."
        case .commissioner:
            return "Every accepted trade waits for you to approve in the Trades tab before executing."
        case .leagueVote:
            return "Accepted trades open for league veto for the configured window. Majority of other owners can reverse them."
        }
    }

    // MARK: - Draft picks

    private var pickAssetsSection: some View {
        Section {
            Button {
                Task { await generatePicks() }
            } label: {
                HStack {
                    Image(systemName: "ticket")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FFColor.accent)
                    Text("Generate \(league.season + 1) picks (4 rounds)")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    if generatingPicks {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(generatingPicks)
            if let pickGenResult {
                Text(pickGenResult)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
        } header: {
            Text("Draft picks").ffEyebrow()
        } footer: {
            Text("Creates one tradeable pick per team and round for next season's draft. Safe to run again — existing picks aren't duplicated.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private func generatePicks() async {
        generatingPicks = true; defer { generatingPicks = false }
        do {
            let created = try await app.ensurePickAssets(
                leagueID: league.id, season: league.season + 1
            )
            pickGenResult = created > 0
                ? "Created \(created) new pick\(created == 1 ? "" : "s")."
                : "All \(league.season + 1) picks already exist."
            Haptics.success()
        } catch {
            pickGenResult = nil
            self.error = "Couldn't generate picks: \(error.localizedDescription)"
        }
    }

    // MARK: - Members

    private var membersSection: some View {
        Section {
            ForEach(league.teams) { team in
                memberRow(team)
            }
        } header: {
            Text("Members").ffEyebrow()
        } footer: {
            Text("Kicking removes the owner but keeps the team and its roster intact, so a new manager can claim it with the join code.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    @ViewBuilder
    private func memberRow(_ team: FantasyTeam) -> some View {
        let isMine    = team.ownerID == app.session?.userID
        let isOpen    = team.ownerID == nil
        let isEditing = editingTeamID == team.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: FFSpace.s) {
                if isEditing {
                    TextField("Team name", text: $editingTeamName)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitRename(teamID: team.id) } }
                } else {
                    Text(team.name)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                }
                if isMine { CommissionerBadge(compact: true) }
                if isOpen {
                    Text("OPEN")
                        .ffEyebrow(color: FFColor.warning)
                }
                Spacer()
                if isEditing {
                    Button("Save") { Task { await commitRename(teamID: team.id) } }
                        .font(.ffCaption.bold())
                        .foregroundStyle(FFColor.accent)
                } else {
                    Button {
                        editingTeamID = team.id
                        editingTeamName = team.name
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
            HStack {
                Text("\(team.roster.count)/\(rosterConfig.totalSize) players")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                Spacer()
                if !isMine && !isOpen {
                    Button(role: .destructive) {
                        teamToKick = TeamRef(id: team.id, name: team.name)
                    } label: {
                        Text("Kick").font(.ffCaption.bold())
                            .foregroundStyle(FFColor.negative)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func teamName(_ teamID: String) -> String {
        league.teams.first(where: { $0.id == teamID })?.name ?? "Unknown team"
    }

    // MARK: - Actions

    private func commitRename(teamID: String) async {
        let name = editingTeamName
        editingTeamID = nil
        do {
            if let updated = try await app.renameTeam(teamID: teamID, name: name) {
                onSave(updated)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func kick(teamID: String) async {
        do {
            if let updated = try await app.kickTeamOwner(teamID: teamID) {
                onSave(updated)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Season (history / rollover)

    private var seasonSection: some View {
        Section {
            if league.seasonCompleted {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(FFColor.positive)
                    Text("Season completed")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    if let at = league.seasonCompletedAt {
                        Text(at.formatted(date: .abbreviated, time: .omitted))
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
                Stepper(value: $rolloverSeason, in: 1990...2100) {
                    HStack {
                        Text("Next season")
                            .font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text(String(rolloverSeason))
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
                Button {
                    Task { await performRollover() }
                } label: {
                    HStack {
                        if rollingOver { ProgressView().controlSize(.small).tint(FFColor.bg) }
                        Text(rollingOver ? "Creating…" : "Roll over to \(rolloverSeason)")
                    }
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                    .background(FFColor.accent, in: Capsule())
                    .foregroundStyle(FFColor.bg)
                }
                .buttonStyle(.plain)
                .disabled(rollingOver)
            } else {
                Button {
                    confirmingComplete = true
                } label: {
                    HStack {
                        if completing { ProgressView().controlSize(.small).tint(FFColor.accent) }
                        Image(systemName: "flag.checkered")
                        Text(completing ? "Archiving…" : "Complete season")
                    }
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.accent)
                }
                .buttonStyle(.plain)
                .disabled(completing)
                .alert("Complete this season?", isPresented: $confirmingComplete) {
                    Button("Cancel", role: .cancel) {}
                    Button("Complete season") {
                        Task { await performComplete() }
                    }
                } message: {
                    Text("Freezes the final standings + every matchup into the league's history. You can then start a new season that links back to this one.")
                }
            }
        } header: {
            Text("Season").ffEyebrow()
        } footer: {
            Text(league.seasonCompleted
                ? (league.isDynasty
                    ? "Rolling over carries every team and roster into the new season with the same settings; the join code is regenerated."
                    : "Rolling over carries every team and manager into the new season with the same settings; rosters are cleared for a fresh draft and the join code is regenerated.")
                : "Completing a season is permanent — the standings snapshot is the source of truth going forward.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
        .onAppear {
            rolloverSeason = max(rolloverSeason, league.season + 1)
        }
    }

    private func performComplete() async {
        completing = true; defer { completing = false }
        do {
            if let updated = try await app.completeLeagueSeason(leagueID: league.id) {
                onSave(updated)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performRollover() async {
        rollingOver = true; defer { rollingOver = false }
        do {
            _ = try await app.rolloverLeague(
                parentID: league.id, newSeason: rolloverSeason, newName: nil
            )
            await app.reloadLeagues()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Danger zone

    private var dangerSection: some View {
        Section {
            if !showingDeletePanel {
                Button(role: .destructive) {
                    showingDeletePanel = true
                    deleteConfirmText = ""
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete league")
                    }
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.negative)
                }
            } else {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("This permanently deletes the league, all teams, rosters, draft picks, trades, and transaction history. It can't be undone.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                    Text("Type \u{201C}\(league.name)\u{201D} to confirm.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                    TextField("", text: $deleteConfirmText,
                              prompt: Text(league.name).foregroundColor(FFColor.textTertiary))
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($deleteFieldFocused)
                        .padding(FFSpace.m)
                        .background(FFColor.bg, in: RoundedRectangle(cornerRadius: FFRadius.s))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.s)
                                .strokeBorder(deleteConfirmText == league.name
                                              ? FFColor.negative
                                              : FFColor.border, lineWidth: 1)
                        )
                    HStack(spacing: FFSpace.s) {
                        // .buttonStyle(.plain) prevents SwiftUI's Form from
                        // broadcasting the row's tap area to this button.
                        // Without it, tapping outside the text field above
                        // (to dismiss the keyboard) would land on Cancel and
                        // collapse the whole panel.
                        Button("Cancel") {
                            showingDeletePanel = false
                            deleteConfirmText = ""
                        }
                        .font(.ffCaption.bold())
                        .foregroundStyle(FFColor.textSecondary)
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            Task { await performDelete() }
                        } label: {
                            HStack(spacing: 6) {
                                if deleting { ProgressView().controlSize(.small).tint(FFColor.bg) }
                                Text(deleting ? "Deleting…" : "Delete league")
                            }
                            .font(.ffCaption.bold())
                            .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                            .background(
                                canDelete ? FFColor.negative : FFColor.surfaceElevated,
                                in: Capsule()
                            )
                            .foregroundStyle(canDelete ? FFColor.bg : FFColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canDelete || deleting)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Danger zone").ffEyebrow(color: FFColor.negative)
        }
        .listRowBackground(FFColor.surface)
    }

    private var canDelete: Bool {
        deleteConfirmText == league.name
    }

    private func performDelete() async {
        guard canDelete else { return }
        deleting = true
        await app.deleteLeague(league.id)
        deleting = false
        // Notify the parent so it can pop the navigation stack. The settings
        // sheet itself goes away when the parent dismisses.
        onDelete?()
        dismiss()
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            // Apply each settings cluster in turn; each call returns the
            // refreshed league, so we thread the final one out to the caller.
            let divisions = divisionsEnabled ? divisionNames
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } : []
            // Taxi off zeroes the slot count; on keeps at least one slot.
            var cfg = rosterConfig
            cfg.taxi = taxiEnabled ? max(1, cfg.taxi) : 0
            // Playoff start week drives the regular-season length. When it
            // changes, regenerate the (prefix-stable) round-robin so already
            // played weeks keep their matchups and the new length lines up.
            let newRegularSeasonWeeks = playoffTeams >= 2
                ? playoffStartWeek - 1
                : league.regularSeasonWeeks
            let newSchedule = newRegularSeasonWeeks != league.regularSeasonWeeks
                ? Fantasy.generateSchedule(teamIDs: league.teams.map(\.id), weeks: newRegularSeasonWeeks)
                : league.schedule
            var latest: League? = try await app.updateLeague(
                leagueID: league.id, name: leagueName,
                scoring: scoring, rosterConfig: cfg,
                playoffTeams: playoffTeams, playoffReseed: playoffReseed,
                scoringSettings: useCustomScoring ? scoringSettings : nil,
                divisionNames: divisions,
                regularSeasonWeeks: newRegularSeasonWeeks,
                weeksPerRound: weeksPerRound,
                schedule: newSchedule,
                keeperCount: min(keeperCount, max(0, cfg.totalSize - 1)),
                keeperRoundCost: keeperCount > 0 && keeperRoundCost,
                keeperDeadline: keeperCount > 0 && hasKeeperDeadline ? keeperDeadline : nil,
                tiebreaker: tiebreaker
            )
            // Push per-team division assignments when divisions are on.
            if divisionsEnabled, divisions.count >= 2 {
                for team in league.teams {
                    let d = min(teamDivisions[team.id] ?? 0, divisions.count - 1)
                    if team.division != d {
                        latest = try await app.setTeamDivision(teamID: team.id, division: d) ?? latest
                    }
                }
            }
            latest = try await app.updateWaiverSettings(
                leagueID: league.id, settings: waiverSettings, priority: priority
            ) ?? latest
            latest = try await app.updateTradeSettings(
                leagueID: league.id, settings: tradeSettings
            ) ?? latest
            if let latest { onSave(latest) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
