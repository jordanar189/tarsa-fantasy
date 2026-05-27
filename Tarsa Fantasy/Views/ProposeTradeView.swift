import SwiftUI

// Modal for composing a trade. Used for fresh proposals AND counter-offers
// (when counterOf is set, the parent trade is referenced + the recipient is
// pre-selected as the other party).
//
// Flow: pick recipient → pick players from each roster → optional note → send.
// Roster validity is checked client-side just for the UI; the propose_trade
// RPC re-validates server-side.
struct ProposeTradeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let fromTeam: FantasyTeam
    let counterOf: Trade?
    let onDone: (Trade?) -> Void

    @State private var recipientID: String? = nil
    @State private var sendingPlayerIDs: Set<String> = []
    @State private var requestingPlayerIDs: Set<String> = []
    @State private var note: String = ""
    @State private var saving: Bool = false
    @State private var error: String? = nil
    @State private var values: [String: Double] = [:]
    @State private var valuationPlayers: [String: Player] = [:]

    init(league: League, fromTeam: FantasyTeam, counterOf: Trade?,
         requestPlayer: (teamID: String, playerID: String)? = nil,
         onDone: @escaping (Trade?) -> Void) {
        self.league = league
        self.fromTeam = fromTeam
        self.counterOf = counterOf
        self.onDone = onDone
        if let counterOf {
            // Counter: I become the proposer, the original proposer becomes
            // recipient. Pre-fill with the original ask (mirrored).
            _recipientID         = State(initialValue: counterOf.proposerTeamID)
            _sendingPlayerIDs    = State(initialValue: Set(counterOf.recipientPlayerIDs))
            _requestingPlayerIDs = State(initialValue: Set(counterOf.proposerPlayerIDs))
        } else if let requestPlayer {
            // Started from a player's profile / the Players list: pre-select that
            // player's team as the partner and put them on the request side.
            _recipientID         = State(initialValue: requestPlayer.teamID)
            _requestingPlayerIDs = State(initialValue: [requestPlayer.playerID])
        }
    }

    private var recipientTeam: FantasyTeam? {
        guard let id = recipientID else { return nil }
        return league.teams.first(where: { $0.id == id })
    }

    private var otherTeams: [FantasyTeam] {
        league.teams.filter { $0.id != fromTeam.id && $0.ownerID != nil }
    }

    private var canSend: Bool {
        recipientID != nil && (!sendingPlayerIDs.isEmpty || !requestingPlayerIDs.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.xl) {
                        recipientPicker
                        if recipientTeam != nil {
                            rosterSection(team: fromTeam, label: "YOU SEND", selected: $sendingPlayerIDs)
                            rosterSection(team: recipientTeam!, label: "YOU REQUEST", selected: $requestingPlayerIDs)
                            balanceCard
                            noteField
                        }
                        if let error {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(FFSpace.l)
                }
            }
            .navigationTitle(counterOf == nil ? "Propose trade" : "Counter offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(counterOf == nil ? "Send" : "Counter") {
                        Task { await send() }
                    }
                    .foregroundStyle(canSend ? FFColor.accent : FFColor.textTertiary)
                    .disabled(!canSend || saving)
                }
            }
            .task {
                await app.ensureProjectedSnapshot(season: league.season)
                let snapshot = Fantasy.playersFor(league: league, snapshot: app.displayPlayers(season: league.season))
                valuationPlayers = snapshot
                values = Fantasy.tradeValues(
                    players: snapshot, scoring: league.scoring,
                    settings: league.scoringSettings, config: league.rosterConfig,
                    teamCount: league.teams.count,
                    valueRatings: app.selectedLeagueValueMap()
                )
            }
        }
        .hostsPlayerProfileSheet()
    }

    // Live fairness gauge. Each side is valued by what it *receives*: you get the
    // requested players, they get the ones you send.
    private var balanceCard: some View {
        TradeBalanceView(
            players: valuationPlayers,
            values: values,
            leftName: "You",
            leftReceives: Array(requestingPlayerIDs),
            rightName: recipientTeam?.name ?? "Them",
            rightReceives: Array(sendingPlayerIDs),
            valueRatings: app.selectedLeagueValueMap()
        )
    }

    private var recipientPicker: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("TRADE WITH").ffEyebrow()
            Menu {
                ForEach(otherTeams) { t in
                    Button(t.name) {
                        if recipientID != t.id {
                            recipientID = t.id
                            requestingPlayerIDs = []
                        }
                    }
                }
            } label: {
                HStack {
                    Text(recipientTeam?.name ?? "Choose a team")
                        .font(.ffBody)
                        .foregroundStyle(recipientTeam == nil ? FFColor.textTertiary : FFColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.s)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
            }
            .disabled(counterOf != nil)
        }
    }

    private func rosterSection(team: FantasyTeam, label: String, selected: Binding<Set<String>>) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(label).ffEyebrow()
                Spacer()
                Text("\(selected.wrappedValue.count) selected")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
            if team.roster.isEmpty {
                Text("Empty roster.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.m)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(team.roster, id: \.self) { pid in
                        playerRow(pid: pid, teamID: team.id, players: players,
                                  isSelected: selected.wrappedValue.contains(pid)) {
                            if selected.wrappedValue.contains(pid) {
                                selected.wrappedValue.remove(pid)
                            } else {
                                selected.wrappedValue.insert(pid)
                            }
                        }
                    }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
            }
        }
    }

    private func playerRow(pid: String, teamID: String, players: [String: Player],
                           isSelected: Bool, toggle: @escaping () -> Void) -> some View {
        let p = players[pid]
        let summary = p.map { Fantasy.summary($0, scoring: league.scoring) }
        let value = app.playerValue(teamID: teamID, playerID: pid)
        // Row tap toggles selection; tapping the name opens the player profile
        // (descendant tap takes precedence over the row's tap).
        return HStack(spacing: FFSpace.m) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? FFColor.accent : FFColor.textTertiary)
            if let summary {
                PlayerAvatar(url: summary.headshotURL, fallback: summary.name.initialsFromName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: summary.position)
                        Text(summary.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        if let value { PlayerValueBadge(value: value) }
                    }
                }
                .playerLink(pid)
                Spacer()
                Text(summary.points.fpString)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textSecondary)
            } else {
                Text(pid).font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
            }
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("NOTE (OPTIONAL)").ffEyebrow()
            TextField("", text: $note, prompt: Text("Why's this a fair deal?").foregroundColor(FFColor.textTertiary), axis: .vertical)
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .lineLimit(2...5)
                .padding(FFSpace.m)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.s)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
        }
    }

    private func send() async {
        guard let recipientID else { return }
        saving = true; defer { saving = false }
        do {
            let trade = try await app.proposeTrade(
                leagueID: league.id,
                proposerTeamID: fromTeam.id,
                recipientTeamID: recipientID,
                proposerPlayerIDs: Array(sendingPlayerIDs),
                recipientPlayerIDs: Array(requestingPlayerIDs),
                note: note.isEmpty ? nil : note,
                parentTradeID: counterOf?.id
            )
            onDone(trade)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
