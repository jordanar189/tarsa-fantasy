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
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                Form {
                    inviteSection
                    generalSection
                    rosterSection
                    waiversSection
                    tradesSection
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
                    Button("Save") { Task { await save() } }
                        .foregroundStyle(FFColor.accent)
                        .disabled(saving)
                }
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
            HStack {
                Text("Join code").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
                Text(league.joinCode)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
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
            Text("Share this code with friends so they can claim open teams. Only commissioners see it.")
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
            rosterStepper("K",     value: $rosterConfig.k,     range: 0...2)
            rosterStepper("DEF",   value: $rosterConfig.def,   range: 0...2)
            rosterStepper("Bench", value: $rosterConfig.bench, range: 0...12)
            HStack {
                Text("Total").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text("\(rosterConfig.starterCount) starters · \(rosterConfig.totalSize) max")
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
            Text("Shrinking the roster is allowed even if a team currently has more players — they'll just be unable to add new ones until they drop.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
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

    private func rosterWarning() -> String? {
        let newTotal = rosterConfig.totalSize
        let over = league.teams.filter { $0.roster.count > newTotal }
        guard !over.isEmpty else { return nil }
        return "\(over.count) team\(over.count == 1 ? "" : "s") currently exceed the new roster size and won't be able to add until they drop."
    }

    // MARK: - Waivers

    private var waiversSection: some View {
        Section {
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
            Text("When approval is on, every add/drop and waiver claim by another manager waits for you in Activity. Priority #1 wins contested claims first; winners roll to the back automatically.")
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
                ? "Rolling over creates a fresh league for the new season with the same settings; the join code is regenerated."
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
            var latest: League? = try await app.updateLeague(
                leagueID: league.id, name: leagueName,
                scoring: scoring, rosterConfig: rosterConfig
            )
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
