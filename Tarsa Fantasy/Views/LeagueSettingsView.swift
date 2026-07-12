import SwiftUI

// Commissioner-only settings sheet. The root shows invite + general and a
// short list of pushed pages (Views/Settings/) so no one screen carries all
// thirteen sections; the Danger Zone stays here at the root. The root owns
// every batched setting as @State and commits the batch with Save — pushed
// pages edit that state through bindings. Immediate per-team actions
// (rename/kick, season lifecycle) live on their own pages.
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
    // Taxi squad + keepers
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
    @State private var confirmingRetroactive: Bool = false

    @State private var saving: Bool = false
    @State private var error: String? = nil

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
                    pagesSection
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
        }
    }

    // MARK: - Pushed pages

    // The section list: one row per settings page, each summarizing its
    // current value so the root reads as an overview.
    private var pagesSection: some View {
        Section {
            pageLink("person.3", "Roster & keepers",
                     "\(rosterConfig.starterCount) starters · \(rosterConfig.totalSize) max") {
                RosterSettingsPage(
                    league: league, rosterConfig: $rosterConfig,
                    keeperCount: $keeperCount, keeperRoundCost: $keeperRoundCost,
                    hasKeeperDeadline: $hasKeeperDeadline, keeperDeadline: $keeperDeadline,
                    taxiEnabled: $taxiEnabled
                )
            }
            pageLink("plusminus.circle", "Scoring",
                     useCustomScoring ? "Custom per-stat weights" : "\(scoring.label) preset") {
                ScoringSettingsPage(
                    scoring: scoring,
                    useCustomScoring: $useCustomScoring,
                    scoringSettings: $scoringSettings
                )
            }
            pageLink("trophy", "Playoffs",
                     playoffTeams >= 2 ? "\(playoffTeams) teams · from Week \(playoffStartWeek)" : "Off") {
                PlayoffsSettingsPage(
                    league: league,
                    playoffTeams: $playoffTeams, playoffReseed: $playoffReseed,
                    tiebreaker: $tiebreaker, playoffStartWeek: $playoffStartWeek,
                    weeksPerRound: $weeksPerRound
                )
            }
            pageLink("square.grid.2x2", "Divisions",
                     divisionsEnabled ? "\(divisionNames.count) divisions" : "Off") {
                DivisionsSettingsPage(
                    league: league,
                    divisionsEnabled: $divisionsEnabled,
                    divisionNames: $divisionNames,
                    teamDivisions: $teamDivisions
                )
            }
            pageLink("arrow.up.arrow.down", "Waivers",
                     waiverSettings.mode == .faab
                        ? "FAAB · $\(waiverSettings.faabBudget) budget"
                        : "Rolling priority") {
                WaiversSettingsPage(
                    league: league,
                    waiverSettings: $waiverSettings,
                    priority: $priority
                )
            }
            pageLink("arrow.left.arrow.right", "Trades", tradeSettings.approval.label) {
                TradesSettingsPage(
                    tradeSettings: $tradeSettings,
                    hasTradeDeadline: $hasTradeDeadline
                )
            }
            pageLink("person.crop.circle.badge.checkmark", "Members",
                     "\(league.teams.count) teams") {
                MembersSettingsPage(
                    league: league, rosterConfig: rosterConfig,
                    onSave: onSave, error: $error
                )
            }
            pageLink("flag.checkered", "Season",
                     league.seasonCompleted ? "Completed — ready to roll over" : "In progress") {
                SeasonSettingsPage(
                    league: league, onSave: onSave,
                    onRolledOver: { dismiss() },
                    error: $error
                )
            }
        } header: {
            Text("Settings").ffEyebrow()
        } footer: {
            Text("Changes made on these pages are applied when you tap Save. Member and season actions apply immediately.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private func pageLink<Destination: View>(
        _ icon: String, _ title: String, _ subtitle: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: FFSpace.m) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FFColor.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                    Text(subtitle).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
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
