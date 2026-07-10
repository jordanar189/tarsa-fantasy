import SwiftUI

// The live draft room. Subscribes to the draft + draft_picks realtime feeds
// so every owner sees picks roll in. Renders the on-the-clock team, a
// countdown timer, the available-players list, and a per-round pick board.
//
// Any connected client whose local countdown hits zero will call the
// auto-pick path — this is safer than relying solely on the per-minute cron,
// which can lag by up to a minute. The RPC validates the deadline so
// duplicate auto-picks are harmless (only one will succeed).
struct DraftRoomView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let leagueID: String

    @State private var league: League? = nil
    @State private var draft: Draft? = nil
    @State private var picks: [DraftPick] = []
    @State private var loading: Bool = true
    @State private var tab: RoomTab = .players
    @State private var query: String = ""
    @State private var position: Position = .all
    @State private var confirmPlayer: PlayerSummary? = nil
    @State private var saving: Bool = false
    @State private var error: String? = nil
    @State private var autoPicking: Bool = false
    // Commissioner action: tap "Make pick for this team" → opens sheet to
    // pick a player on their behalf.
    @State private var pickingForTeam: FantasyTeam? = nil
    @State private var lastSeenPick: Int = 0
    @State private var showingTeamManager: Bool = false
    @State private var showingKeeperPicker: Bool = false
    @State private var adp: [String: Double] = [:]
    // Auction state: full lot list (sold rows double as the results board)
    // and the player pending a nomination amount.
    @State private var lots: [AuctionLot] = []
    @State private var nominating: PlayerSummary? = nil
    // League-wide auction dollar values (tradeValues normalized so the top
    // total_picks players share the league's combined budget). Drives bot
    // bidding in sims; display-only otherwise.
    @State private var dollarValues: [String: Int] = [:]
    @State private var botActing: Bool = false
    // Per-user, per-draft queue. Strictly overrides the auto-pick loop:
    // if a queued player is still available when the user's auto-pick
    // fires, they're taken before the loop strategy considers anyone.
    @State private var queue: [String] = []

    enum RoomTab: String, CaseIterable, Identifiable, Hashable {
        case players = "Players"
        case board   = "Board"
        case teams   = "Teams"
        case queue   = "Queue"
        case mine    = "My picks"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            if let draft, let league {
                content(draft: draft, league: league)
            } else if loading {
                ProgressView().tint(FFColor.accent)
            } else {
                noDraft
            }
        }
        .navigationTitle("Draft")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .task(id: leagueID) { await initialLoad() }
        .onDisappear { Task { await DraftListener.shared.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: .draftUpdated)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .draftPicksUpdated)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .auctionLotsUpdated)) { _ in
            Task { await reload() }
        }
        .sheet(item: $nominating) { player in
            if let draft, let league,
               let myTeam = league.teams.first(where: { $0.ownerID == app.session?.userID }) {
                NominationSheet(
                    player: player,
                    maxBid: auctionMaxBid(draft: draft, teamID: myTeam.id)
                ) { amount in
                    Task { await nominate(player: player, teamID: myTeam.id, amount: amount) }
                }
            }
        }
        .alert(item: $confirmPlayer) { player in
            Alert(
                title: Text("Draft \(player.name)?"),
                message: Text("This pick can't be undone."),
                primaryButton: .default(Text("Draft")) {
                    Task { await pick(player) }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $pickingForTeam) { team in
            if let league {
                CommishPickerSheet(
                    league: league, team: team,
                    pickedPlayerIDs: Set(picks.map(\.playerID))
                        .union(league.teams.flatMap(\.keepers))
                ) { player in
                    Task { await pickOnBehalf(of: team, player: player) }
                }
            }
        }
        .sheet(isPresented: $showingTeamManager) {
            if let draft, let league {
                DraftTeamManagerSheet(
                    draft: draft, league: league, picks: picks,
                    onChanged: { updated in self.draft = updated },
                    onPickForTeam: { team in pickingForTeam = team }
                )
            }
        }
        .sheet(isPresented: $showingKeeperPicker) {
            if let league,
               let myTeam = league.teams.first(where: { $0.ownerID == app.session?.userID }) {
                KeeperSelectionSheet(league: league, team: myTeam) { updated in
                    self.league = updated
                }
            }
        }
        // Auto-mode trigger — when current_pick changes (via realtime or
        // any local reload) and the new on-clock team is in auto mode,
        // queue up an auto-pick. Tracks last seen so we only fire once per
        // pick transition.
        .onChange(of: draft?.currentPick) { _, new in
            guard let new, new != lastSeenPick else { return }
            lastSeenPick = new
            Task { await maybeAutoPickForAutoTeam() }
        }
        // Sim auctions: this client drives the bot teams (it owns them), so
        // mock auctions move at conversation pace instead of waiting on the
        // per-minute cron. No-ops instantly outside test-league auctions.
        .task(id: leagueID) { await auctionBotLoop() }
    }

    // MARK: - Load / refresh

    private func initialLoad() async {
        loading = true
        await reload()
        loading = false
        if let did = draft?.id {
            await DraftListener.shared.start(draftID: did)
        }
    }

    private func reload() async {
        league = await app.league(leagueID)
        if let lg = league {
            draft = await app.draft(leagueID: lg.id)
            if let did = draft?.id {
                picks = await app.draftPicks(draftID: did)
                if draft?.format == .auction {
                    lots = await app.auctionLots(draftID: did)
                }
                if let myTeam = lg.teams.first(where: { $0.ownerID == app.session?.userID }) {
                    queue = await app.draftQueue(draftID: did, teamID: myTeam.id)
                }
            }
            // ADP only changes when the daily cron refreshes — fetch once per
            // reload (cheap; data actor caches in-process).
            if adp.isEmpty {
                adp = await app.adp(season: lg.season, scoring: lg.scoring)
            }
            // Surface projected points on the board when drafting a season that
            // hasn't kicked off yet (display only — pick logic stays on real data).
            await app.loadSeason(lg.season)
            await app.ensureProjectedSnapshot(season: lg.season)
        }
    }

    // MARK: - Body chunks

    @ViewBuilder
    private func content(draft: Draft, league: League) -> some View {
        ScrollView {
            VStack(spacing: FFSpace.l) {
                statusHeader(draft: draft, league: league)
                SegmentedTabPicker(items: RoomTab.allCases, selection: $tab) {
                    Text($0.rawValue)
                }
                switch tab {
                case .players: playersList(draft: draft, league: league)
                case .board:
                    if draft.format == .auction {
                        auctionBoard(draft: draft, league: league)
                    } else {
                        boardView(draft: draft, league: league)
                    }
                case .teams:   teamsRosterView(draft: draft, league: league)
                case .queue:   queueView(draft: draft, league: league)
                case .mine:    myPicks(draft: draft, league: league)
                }
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.bottom, 40)
        }
    }

    private var noDraft: some View {
        VStack(spacing: FFSpace.l) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No draft scheduled")
                .font(.ffTitle).foregroundStyle(FFColor.textPrimary)
            Text("The commissioner hasn't set up a draft for this league.")
                .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(FFSpace.xxl)
    }

    // MARK: - Status header

    @ViewBuilder
    private func statusHeader(draft: Draft, league: League) -> some View {
        let onClockTeamID = draft.teamOnClock(forPick: draft.currentPick)
        let onClockTeam = league.teams.first(where: { $0.id == onClockTeamID })
        let isMyTurn = onClockTeam?.ownerID == app.session?.userID
        let isCommish = league.creatorID == app.session?.userID

        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                statusPill(draft.status)
                Spacer()
                Text(draft.format == .auction
                     ? "PLAYER \(min(soldLots.count + 1, draft.totalPicks))/\(draft.totalPicks) · $\(draft.auctionBudget) BUDGET"
                     : "ROUND \(draft.currentRound) · PICK \(draft.currentPick)/\(draft.totalPicks)")
                    .ffEyebrow(color: FFColor.textTertiary)
            }

            switch draft.status {
            case .scheduled:
                scheduledHeader(draft: draft, league: league, isCommish: isCommish)
            case .live:
                if draft.format == .auction {
                    auctionHeader(draft: draft, league: league)
                } else {
                    liveHeader(draft: draft, league: league, onClockTeam: onClockTeam, isMyTurn: isMyTurn, isCommish: isCommish)
                }
            case .paused:
                pausedHeader(draft: draft, isCommish: isCommish)
            case .complete:
                completeHeader(draft: draft)
            }
        }
        .ffCard()
    }

    @ViewBuilder
    private func scheduledHeader(draft: Draft, league: League, isCommish: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = draft.startsAt.timeIntervalSinceNow
            let myTeam = league.teams.first(where: { $0.ownerID == app.session?.userID })
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("Starts in").ffEyebrow()
                Text(formatCountdown(remaining))
                    .font(.ffStatLarge)
                    .foregroundStyle(remaining <= 0 ? FFColor.accent : FFColor.textPrimary)
                Text(draft.startsAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                // Keeper-lite: owners lock keepers in before the draft starts.
                if league.keeperCount > 0, let myTeam, !myTeam.roster.isEmpty {
                    Button {
                        showingKeeperPicker = true
                    } label: {
                        Text("Keepers: \(myTeam.keepers.count)/\(league.keeperCount) selected")
                    }
                    .ffSecondaryButton()
                    .padding(.top, FFSpace.s)
                    if let deadline = league.keeperDeadline {
                        Text(deadline < Date()
                             ? "Keeper deadline passed \(deadline.shortRelative)."
                             : "Keeper deadline \(deadline.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.ffMicro)
                            .foregroundStyle(deadline < Date() ? FFColor.negative : FFColor.textTertiary)
                    }
                }
                if isCommish && remaining <= 0 {
                    Button {
                        Task {
                            do {
                                let updated = try await app.startDraft(draftID: draft.id)
                                if let updated { self.draft = updated }
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        Text("Start draft now")
                    }
                    .ffPrimaryButton()
                    .padding(.top, FFSpace.s)
                } else if isCommish {
                    Text("You'll be able to start the draft once the scheduled time arrives.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func liveHeader(draft: Draft, league: League, onClockTeam: FantasyTeam?, isMyTurn: Bool, isCommish: Bool) -> some View {
        VStack(spacing: FFSpace.s) {
            DraftOnTheClockWidget(
                draft: draft, league: league, session: app.session,
                onPause: {
                    Task {
                        do {
                            let updated = try await app.pauseDraft(draftID: draft.id)
                            if let updated { self.draft = updated }
                        } catch { self.error = error.localizedDescription }
                    }
                },
                onAutoPickToggle: { team, enabled in
                    Task { await toggleAutoPick(team: team, enabled: enabled) }
                },
                onPickForTeam: { team in
                    pickingForTeam = team
                },
                onManageTeams: {
                    showingTeamManager = true
                }
            )
            // Tick the local clock so we can fire expiry / auto-mode picks.
            if let deadline = draft.pickDeadline {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Color.clear
                        .frame(height: 0)
                        .onChange(of: deadline.timeIntervalSinceNow <= 0) { _, expired in
                            if expired { Task { await maybeAutoPick(draft: draft) } }
                        }
                }
            }
        }
    }

    // MARK: - Auction

    private var openLot: AuctionLot? { lots.first(where: \.isOpen) }
    private var soldLots: [AuctionLot] { lots.filter { !$0.isOpen } }

    // Client mirrors of the server helpers — display only; every rule is
    // re-validated by the RPCs.
    private func auctionSlotsPerTeam(draft: Draft) -> Int {
        let n = max(draft.pickOrder.count, 1)
        return draft.totalPicks / n
    }
    private func auctionSpent(teamID: String) -> Int {
        soldLots.filter { $0.currentBidderTeamID == teamID }
            .compactMap(\.soldPrice).reduce(0, +)
    }
    private func auctionWon(teamID: String) -> Int {
        soldLots.filter { $0.currentBidderTeamID == teamID }.count
    }
    private func auctionMaxBid(draft: Draft, teamID: String) -> Int {
        let remaining = auctionSlotsPerTeam(draft: draft) - auctionWon(teamID: teamID)
        guard remaining > 0 else { return 0 }
        return max(0, draft.auctionBudget - auctionSpent(teamID: teamID) - (remaining - 1))
    }
    private func auctionNominatorID(draft: Draft) -> String? {
        let n = draft.pickOrder.count
        guard n > 0 else { return nil }
        return draft.pickOrder[(draft.currentPick - 1) % n]
    }

    @ViewBuilder
    private func auctionHeader(draft: Draft, league: League) -> some View {
        let myTeam = league.teams.first(where: { $0.ownerID == app.session?.userID })
        if let lot = openLot {
            auctionLotCard(lot: lot, draft: draft, league: league, myTeam: myTeam)
        } else {
            nominationBanner(draft: draft, league: league, myTeam: myTeam)
        }
    }

    @ViewBuilder
    private func auctionLotCard(lot: AuctionLot, draft: Draft, league: League, myTeam: FantasyTeam?) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.displayPlayers(season: league.season))
        let summary = players[lot.playerID].map { Fantasy.summary($0, scoring: league.scoring) }
        let leader = league.teams.first(where: { $0.id == lot.currentBidderTeamID })
        let iLead = myTeam?.id == lot.currentBidderTeamID
        let myMax = myTeam.map { auctionMaxBid(draft: draft, teamID: $0.id) } ?? 0

        VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack(spacing: FFSpace.m) {
                PlayerAvatar(url: summary?.headshotURL ?? "",
                             fallback: (summary?.name ?? "?").initialsFromName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary?.name ?? lot.playerID)
                        .font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                    HStack(spacing: 6) {
                        if let summary { PositionPill(position: summary.position) }
                        Text(summary?.team ?? "")
                            .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    }
                }
                .playerLink(lot.playerID)
                Spacer()
                if let deadline = lot.bidDeadline {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let remaining = deadline.timeIntervalSince(context.date)
                        countdownDial(remaining: max(0, remaining), total: 15)
                            .onChange(of: remaining <= 0) { _, expired in
                                if expired { Task { await settleIfDue() } }
                            }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("$\(lot.currentBid)")
                    .font(.ffStatLarge)
                    .foregroundStyle(iLead ? FFColor.positive : FFColor.textPrimary)
                Text(iLead ? "you lead" : (leader?.name ?? "—"))
                    .font(.ffCaption)
                    .foregroundStyle(iLead ? FFColor.positive : FFColor.textSecondary)
                Spacer()
                if myTeam != nil {
                    Text("Your max $\(myMax)")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            if let myTeam {
                HStack(spacing: FFSpace.s) {
                    bidButton(amount: lot.currentBid + 1, label: "+$1",
                              lot: lot, team: myTeam, myMax: myMax, iLead: iLead)
                    bidButton(amount: lot.currentBid + 5, label: "+$5",
                              lot: lot, team: myTeam, myMax: myMax, iLead: iLead)
                    bidButton(amount: lot.currentBid + 10, label: "+$10",
                              lot: lot, team: myTeam, myMax: myMax, iLead: iLead)
                }
            }
        }
    }

    private func bidButton(amount: Int, label: String, lot: AuctionLot,
                           team: FantasyTeam, myMax: Int, iLead: Bool) -> some View {
        let enabled = !iLead && amount > lot.currentBid && amount <= myMax && !saving
        return Button {
            Task { await bid(teamID: team.id, amount: amount) }
        } label: {
            Text(label)
                .font(.ffCaption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(enabled ? FFColor.accent : FFColor.surfaceElevated, in: Capsule())
                .foregroundStyle(enabled ? FFColor.bg : FFColor.textTertiary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func nominationBanner(draft: Draft, league: League, myTeam: FantasyTeam?) -> some View {
        let nominatorID = auctionNominatorID(draft: draft)
        let nominator = league.teams.first(where: { $0.id == nominatorID })
        let isMe = myTeam?.id == nominatorID
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isMe ? "Your nomination" : "\(nominator?.name ?? "—") is nominating")
                        .font(.ffHeadline)
                        .foregroundStyle(isMe ? FFColor.accent : FFColor.textPrimary)
                    Text(isMe
                         ? "Pick a player from the list below to put up for auction."
                         : "Waiting for their pick — bidding opens the moment it lands.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                }
                Spacer()
                if let deadline = draft.pickDeadline {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        countdownDial(remaining: max(0, deadline.timeIntervalSince(context.date)),
                                      total: Double(draft.pickSeconds))
                    }
                }
            }
        }
    }

    // MARK: - Auction bots (sim leagues)

    // In a simulation every bot team is owned by the viewer, so this client
    // can nominate and bid on their behalf — same trust model as snake mock
    // auto-picks. Bots created by createSimulation are always named "Bot N".
    private var simBotTeams: [FantasyTeam] {
        guard let league, league.isTest else { return [] }
        return league.teams.filter { $0.name.hasPrefix("Bot ") }
    }

    private func auctionBotLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            await driveAuctionBots()
        }
    }

    private func driveAuctionBots() async {
        guard let draft, draft.format == .auction, draft.status == .live,
              !botActing, !simBotTeams.isEmpty else { return }
        botActing = true
        defer { botActing = false }
        await ensureDollarValues()
        var rng = SystemRandomNumberGenerator()

        if let lot = openLot {
            guard let deadline = lot.bidDeadline, deadline > Date() else { return }
            let candidates = simBotTeams.map {
                (teamID: $0.id, maxBid: auctionMaxBid(draft: draft, teamID: $0.id))
            }
            if let bid = BotAI.auctionBid(
                playerID: lot.playerID,
                currentBid: lot.currentBid,
                leaderTeamID: lot.currentBidderTeamID,
                bots: candidates,
                dollarValue: dollarValues[lot.playerID] ?? 1,
                rng: &rng
            ) {
                _ = try? await app.placeBid(draftID: draft.id, teamID: bid.teamID, amount: bid.amount)
                await reload()
            }
        } else if let nomID = auctionNominatorID(draft: draft),
                  simBotTeams.contains(where: { $0.id == nomID }) {
            let taken = Set(lots.map(\.playerID))
                .union((league?.teams ?? []).flatMap(\.roster))
            let ranked = dollarValues
                .sorted { $0.value > $1.value }
                .map(\.key)
                .filter { !taken.contains($0) }
            if let pick = BotAI.auctionNomination(available: Array(ranked.prefix(30)), rng: &rng) {
                _ = try? await app.nominatePlayer(draftID: draft.id, teamID: nomID, playerID: pick, amount: 1)
                await reload()
            }
        }
    }

    // tradeValues → auction dollars: the top total_picks players share the
    // league's combined budget, floor $1. Computed once per room session.
    private func ensureDollarValues() async {
        guard dollarValues.isEmpty, let draft, let league else { return }
        let snapshot = Fantasy.playersFor(league: league, snapshot: app.displayPlayers(season: league.season))
        let values = Fantasy.tradeValues(
            players: snapshot, scoring: league.scoring,
            settings: league.scoringSettings, config: league.rosterConfig,
            teamCount: league.teams.count,
            valueRatings: app.selectedLeagueValueMap()
        )
        guard !values.isEmpty else { return }
        let top = values.values.sorted(by: >).prefix(max(draft.totalPicks, 1))
        let topSum = top.reduce(0, +)
        guard topSum > 0 else { return }
        let pool = Double(draft.auctionBudget * max(league.teams.count, 1))
        dollarValues = values.mapValues { max(1, Int(($0 / topSum * pool).rounded())) }
    }

    // Deadline-gated server-side; every connected client may fire this.
    private func settleIfDue() async {
        guard let draft, draft.format == .auction,
              let lot = openLot, let deadline = lot.bidDeadline,
              deadline <= Date() else { return }
        if let updated = try? await app.settleLot(draftID: draft.id) {
            self.draft = updated
        }
        await reload()
    }

    private func bid(teamID: String, amount: Int) async {
        guard let draft else { return }
        saving = true; defer { saving = false }
        do {
            _ = try await app.placeBid(draftID: draft.id, teamID: teamID, amount: amount)
            Haptics.tap()
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func nominate(player: PlayerSummary, teamID: String, amount: Int) async {
        guard let draft else { return }
        saving = true; defer { saving = false }
        do {
            _ = try await app.nominatePlayer(
                draftID: draft.id, teamID: teamID, playerID: player.id, amount: amount)
            Haptics.success()
            nominating = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
            nominating = nil
        }
    }

    @ViewBuilder
    private func pausedHeader(draft: Draft, isCommish: Bool) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("Paused")
                .font(.ffTitle)
                .foregroundStyle(FFColor.warning)
            if let remaining = draft.pausedRemaining {
                Text("\(remaining)s left on the clock when paused")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
            if isCommish {
                Button {
                    Task {
                        do {
                            let updated = try await app.resumeDraft(draftID: draft.id)
                            if let updated { self.draft = updated }
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Text("Resume")
                }
                .ffPrimaryButton()
                .padding(.top, FFSpace.s)
            }
        }
    }

    private func completeHeader(draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("Draft complete")
                .font(.ffTitle)
                .foregroundStyle(FFColor.accent)
            if let at = draft.completedAt {
                Text("Wrapped \(at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
            if app.isMockLeague(leagueID) {
                if let league {
                    MockDraftGradeCard(league: league, draft: draft)
                }
            } else {
                Text("Rosters are set. Free agency and waivers are now open.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
        }
    }

    private func statusPill(_ s: DraftStatus) -> some View {
        let (label, color): (String, Color) = {
            switch s {
            case .scheduled: return ("SCHEDULED", FFColor.textSecondary)
            case .live:      return ("LIVE",      FFColor.accent)
            case .paused:    return ("PAUSED",    FFColor.warning)
            case .complete:  return ("COMPLETE",  FFColor.positive)
            }
        }()
        return Text(label)
            .font(.ffMicro).tracking(0.8)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
            .foregroundStyle(color)
    }

    private func countdownDial(remaining: TimeInterval, total: Double) -> some View {
        let secs = max(0, Int(remaining.rounded(.up)))
        let frac = max(0, min(1, total == 0 ? 0 : remaining / total))
        let warn = remaining <= 10
        return ZStack {
            Circle().stroke(FFColor.border, lineWidth: 4)
            Circle()
                .trim(from: 0, to: frac)
                .stroke(warn ? FFColor.warning : FFColor.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: frac)
            Text("\(secs)")
                .font(.ffStatMedium)
                .foregroundStyle(warn ? FFColor.warning : FFColor.textPrimary)
        }
        .frame(width: 60, height: 60)
    }

    // MARK: - Players

    @ViewBuilder
    private func playersList(draft: Draft, league: League) -> some View {
        // Display snapshot — projected points in preseason; also feeds
        // starterNeeds for the late-draft position restriction. The actual
        // pick/auto-pick RPCs run on the real snapshot, so projections never
        // affect what gets drafted or scored.
        let players = Fantasy.playersFor(league: league, snapshot: app.displayPlayers(season: league.season))
        // Kept players never enter the pool alongside the already-picked.
        let pickedIDs = Set(picks.map(\.playerID))
            .union(league.teams.flatMap(\.keepers))
        let myTeam = league.teams.first(where: { $0.ownerID == app.session?.userID })
        let onClock = draft.teamOnClock(forPick: draft.currentPick)
        // Auction: the actionable state is "my nomination turn with no lot
        // open" — bidding happens in the header card, not the list.
        let isMyTurn: Bool = {
            guard draft.status == .live, let myID = myTeam?.id else { return false }
            if draft.format == .auction {
                return openLot == nil && auctionNominatorID(draft: draft) == myID
            }
            return myID == onClock
        }()

        // Late-draft starter-need restriction: once your team has only as many
        // picks left as empty starting slots, the picks must all go toward
        // startable positions — so limit the list to those (bench/IR excluded).
        let teamCount = max(draft.pickOrder.count, 1)
        let totalRounds = draft.totalPicks / teamCount
        let myPicks = myTeam.map { t in picks.filter { $0.teamID == t.id }.map(\.playerID) } ?? []
        // Keepers count toward filled starter slots but not toward the
        // (already keeper-reduced) remaining pick budget. In round-cost
        // leagues keepers are real pick rows, so dedupe against myPicks.
        let myRoster = (myTeam?.keepers ?? []).filter { !myPicks.contains($0) } + myPicks
        let remainingPicks = max(0, totalRounds - myPicks.count)
        let needs = myTeam == nil
            ? (positions: Set<String>(), unfilledCount: 0)
            : Fantasy.starterNeeds(
                roster: myRoster, players: players, config: league.rosterConfig,
                scoring: league.scoring, settings: league.scoringSettings
              )
        let needsActive = needs.unfilledCount > 0
            && remainingPicks > 0
            && remainingPicks <= needs.unfilledCount
        let allowedPositions = needs.positions
        let allowedLabel = ["QB", "RB", "WR", "TE", "K", "DEF"]
            .filter { allowedPositions.contains($0) }
            .joined(separator: ", ")
        let chipItems: [Position] = needsActive
            ? [Position.all] + Position.allCases.filter { $0 != .all && allowedPositions.contains($0.rawValue) }
            : Position.allCases
        let effectivePosition: Position = chipItems.contains(position) ? position : .all

        VStack(spacing: FFSpace.s) {
            searchBar
            ChipRow(items: chipItems, selection: $position) { Text($0.label) }

            if needsActive {
                Text("Final picks — only positions you still need to start are draftable: \(allowedLabel).")
                    .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let searched = Fantasy.search(
                players: players, query: query, position: effectivePosition,
                scoring: league.scoring, limit: 0,
                adp: adp.isEmpty ? nil : adp
            ).filter { !pickedIDs.contains($0.id) }
            // Rookie drafts: only the incoming class (mirrors is_rookie).
            let baseRows = draft.isRookieDraft
                ? searched.filter { row in
                    guard let profile = players[row.id]?.profile else { return false }
                    return profile.yearsExp == 0
                        || (profile.yearsExp == nil && profile.draftYear == league.season)
                }
                : searched
            let rows = needsActive
                ? baseRows.filter { allowedPositions.contains($0.position.uppercased()) }
                : baseRows

            if rows.isEmpty {
                Text("No players match.").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, FFSpace.xl)
            } else {
                let visible = Array(rows.prefix(200))
                VStack(spacing: 0) {
                    ForEach(visible) { row in
                        playerRow(row, canPick: isMyTurn)
                    }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
                .prefetchAvatars(urls: visible.map(\.headshotURL))
            }
            if !isMyTurn && draft.status == .live {
                Text("Waiting for your turn — picks will be disabled until you're on the clock.")
                    .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func playerRow(_ row: PlayerSummary, canPick: Bool) -> some View {
        let queued = queue.contains(row.id)
        let viewerHasTeam = league?.teams.contains(where: { $0.ownerID == app.session?.userID }) ?? false
        return HStack(spacing: FFSpace.m) {
            PlayerAvatar(url: row.headshotURL, fallback: row.name.initialsFromName, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    PositionPill(position: row.position)
                    if let injury = app.injuries[row.id] {
                        InjuryBadge(injury: injury)
                    }
                    Text(row.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
            .playerLink(row.id)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let a = adp[row.id] {
                    Text("ADP \(formatADP(a))")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                }
                Text(row.points.fpString)
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
            if viewerHasTeam {
                Button {
                    Task { await toggleQueue(playerID: row.id, queued: queued) }
                } label: {
                    Image(systemName: queued ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(queued ? FFColor.accent : FFColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(queued ? "Remove from queue" : "Add to queue")
            }
            Button {
                if draft?.format == .auction {
                    nominating = row
                } else {
                    confirmPlayer = row
                }
            } label: {
                Text(draft?.format == .auction ? "Nominate" : "Draft")
                    .font(.ffCaption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(canPick ? FFColor.accent : FFColor.surfaceElevated, in: Capsule())
                    .foregroundStyle(canPick ? FFColor.bg : FFColor.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canPick || saving)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - Queue tab

    @ViewBuilder
    private func queueView(draft: Draft, league: League) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let pickedIDs = Set(picks.map(\.playerID))
            .union(league.teams.flatMap(\.keepers))
        let myTeam = league.teams.first(where: { $0.ownerID == app.session?.userID })
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("YOUR QUEUE").ffEyebrow()
                Spacer()
                Text("\(queue.count)")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
            }
            Text("When auto-pick is on, your queued players are taken in order before the strategy fallback. Add players from the Players tab.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textTertiary)

            if myTeam == nil {
                Text("You don't own a team in this league.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(.vertical, FFSpace.l)
            } else if queue.isEmpty {
                Text("Empty.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(.vertical, FFSpace.l)
            } else {
                List {
                    ForEach(Array(queue.enumerated()), id: \.element) { idx, pid in
                        queueRow(idx: idx, playerID: pid, player: players[pid],
                                 isPicked: pickedIDs.contains(pid))
                            .listRowBackground(FFColor.surface)
                            .listRowSeparatorTint(FFColor.border)
                    }
                    .onMove { from, to in
                        var copy = queue
                        copy.move(fromOffsets: from, toOffset: to)
                        queue = copy
                        if let tid = myTeam?.id {
                            Task { try? await app.queueReorder(draftID: draft.id, teamID: tid, playerIDs: copy) }
                        }
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { queue[$0] }
                        queue.remove(atOffsets: offsets)
                        guard let tid = myTeam?.id else { return }
                        Task {
                            for pid in removed {
                                try? await app.queueRemove(draftID: draft.id, teamID: tid, playerID: pid)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
                .frame(minHeight: CGFloat(queue.count * 56 + 8))
            }
        }
    }

    private func queueRow(idx: Int, playerID: String, player: Player?, isPicked: Bool) -> some View {
        HStack(spacing: FFSpace.m) {
            Text("\(idx + 1)")
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.accent)
                .frame(width: 24, alignment: .leading)
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.ffBody)
                        .foregroundStyle(isPicked ? FFColor.textTertiary : FFColor.textPrimary)
                        .strikethrough(isPicked)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: player.position)
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        if isPicked {
                            Text("DRAFTED").ffEyebrow(color: FFColor.textTertiary)
                        }
                    }
                }
                .playerLink(playerID)
                Spacer()
            } else {
                Text(playerID).font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func toggleQueue(playerID: String, queued: Bool) async {
        guard let draft, let lg = league,
              let myTeam = lg.teams.first(where: { $0.ownerID == app.session?.userID })
        else { return }
        do {
            if queued {
                try await app.queueRemove(draftID: draft.id, teamID: myTeam.id, playerID: playerID)
                queue.removeAll { $0 == playerID }
            } else {
                try await app.queueAdd(draftID: draft.id, teamID: myTeam.id, playerID: playerID)
                queue.append(playerID)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Board

    @ViewBuilder
    private func boardView(draft: Draft, league: League) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let teamCount = draft.pickOrder.count
        let rounds = max(1, (draft.totalPicks + teamCount - 1) / max(teamCount, 1))
        let teamsByID = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0) })
        let picksByNumber = Dictionary(uniqueKeysWithValues: picks.map { ($0.pickNumber, $0) })

        VStack(alignment: .leading, spacing: FFSpace.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    // Header row of teams (in round-1 order).
                    HStack(spacing: 4) {
                        Text("R").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 24, alignment: .leading)
                        ForEach(draft.pickOrder, id: \.self) { tid in
                            Text(teamsByID[tid]?.name ?? "—")
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                                .lineLimit(1)
                                .frame(width: 96, alignment: .leading)
                        }
                    }
                    ForEach(0..<rounds, id: \.self) { roundIdx in
                        HStack(spacing: 4) {
                            Text("\(roundIdx + 1)")
                                .font(.ffStatSmall)
                                .foregroundStyle(FFColor.textTertiary)
                                .frame(width: 24, alignment: .leading)
                            ForEach(0..<teamCount, id: \.self) { col in
                                let pickNum = pickNumberAt(round: roundIdx, col: col,
                                                           teamCount: teamCount, format: draft.format)
                                boardCell(pickNum: pickNum, pick: picksByNumber[pickNum],
                                          players: players, currentPick: draft.currentPick)
                            }
                        }
                    }
                }
            }
        }
    }

    private func pickNumberAt(round: Int, col: Int, teamCount: Int, format: DraftFormat) -> Int {
        let pos = (format == .snake && round.isMultiple(of: 2) == false)
            ? (teamCount - 1 - col) : col
        return round * teamCount + pos + 1
    }

    private func boardCell(pickNum: Int, pick: DraftPick?, players: [String: Player], currentPick: Int) -> some View {
        let isCurrent = pickNum == currentPick
        let player = pick.flatMap { players[$0.playerID] }
        // Tint the cell by the picked player's position so the board scans
        // at a glance. Unfilled cells keep the neutral surface; on-clock
        // still gets the accent overlay regardless.
        let backgroundColor: Color = {
            if let p = player {
                return FFColor.positionTint(p.position).opacity(0.22)
            }
            return isCurrent ? FFColor.accentSoft : FFColor.surface
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(pickNum)")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
            if let player {
                Text(player.name)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1)
                Text(player.position)
                    .font(.ffMicro.bold())
                    .foregroundStyle(FFColor.positionTint(player.position))
            } else {
                Text(isCurrent ? "On clock" : "—")
                    .font(.ffCaption)
                    .foregroundStyle(isCurrent ? FFColor.accent : FFColor.textTertiary)
            }
        }
        .padding(6)
        .frame(width: 96, height: 56, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isCurrent ? FFColor.accent : FFColor.border, lineWidth: 1)
        )
        .playerLink(player?.id)
    }

    // MARK: - Teams (opponent rosters)

    @ViewBuilder
    private func teamsRosterView(draft: Draft, league: League) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let onClockTeamID = draft.teamOnClock(forPick: draft.currentPick)
        // Show in draft-order so opponents appear in a stable left-to-right
        // order that matches the Board tab.
        let ordered = draft.pickOrder.compactMap { tid in
            league.teams.first(where: { $0.id == tid })
        }
        VStack(spacing: FFSpace.l) {
            ForEach(ordered) { team in
                let teamPicks = picks
                    .filter { $0.teamID == team.id }
                    .sorted(by: { $0.pickNumber < $1.pickNumber })
                VStack(spacing: 0) {
                    if draft.format == .auction {
                        HStack(spacing: FFSpace.m) {
                            Text("Spent $\(auctionSpent(teamID: team.id))")
                                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                            Text("Max bid $\(auctionMaxBid(draft: draft, teamID: team.id))")
                                .font(.ffCaption).foregroundStyle(FFColor.accent)
                            Spacer()
                            Text("\(auctionWon(teamID: team.id))/\(auctionSlotsPerTeam(draft: draft)) filled")
                                .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        }
                        .padding(.horizontal, FFSpace.s)
                        .padding(.bottom, FFSpace.xs)
                    }
                    teamRosterCard(
                        team: team, teamPicks: teamPicks, players: players,
                        isOnClock: draft.format == .auction
                            ? team.id == auctionNominatorID(draft: draft) && openLot == nil
                            : team.id == onClockTeamID,
                        isMine: team.ownerID == app.session?.userID
                    )
                }
            }
        }
    }

    // Auction results board: every sold lot in nomination order.
    @ViewBuilder
    private func auctionBoard(draft: Draft, league: League) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        if soldLots.isEmpty {
            Text("No players sold yet.")
                .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, FFSpace.xl)
        } else {
            VStack(spacing: 0) {
                ForEach(soldLots.sorted(by: { $0.nominationNumber > $1.nominationNumber })) { lot in
                    HStack(spacing: FFSpace.m) {
                        Text("$\(lot.soldPrice ?? lot.currentBid)")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                            .frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(players[lot.playerID]?.name ?? lot.playerID)
                                .font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                            Text(league.teams.first(where: { $0.id == lot.currentBidderTeamID })?.name ?? "—")
                                .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        }
                        .playerLink(lot.playerID)
                        Spacer()
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.vertical, FFSpace.s)
                    .ffHairlineBottom()
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
        }
    }

    private func teamRosterCard(
        team: FantasyTeam, teamPicks: [DraftPick],
        players: [String: Player], isOnClock: Bool, isMine: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                Text(team.name)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1)
                if isMine {
                    Text("YOU").ffEyebrow(color: FFColor.accent)
                } else if team.ownerID == nil {
                    Text("OPEN").ffEyebrow(color: FFColor.warning)
                }
                Spacer()
                Text("\(teamPicks.count) pick\(teamPicks.count == 1 ? "" : "s")")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textTertiary)
            }
            if teamPicks.isEmpty {
                Text(isOnClock ? "On the clock — no picks yet." : "No picks yet.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(teamPicks) { p in
                        teamPickRow(pick: p, player: players[p.playerID])
                    }
                }
            }
        }
        .ffCard()
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(
                    isOnClock ? FFColor.accent : (isMine ? FFColor.accent.opacity(0.4) : Color.clear),
                    lineWidth: 1
                )
        )
    }

    private func teamPickRow(pick: DraftPick, player: Player?) -> some View {
        HStack(spacing: FFSpace.m) {
            Text("#\(pick.pickNumber)")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
                .frame(width: 36, alignment: .leading)
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: player.position)
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    }
                }
                .playerLink(player.id)
                Spacer()
            } else {
                Text(pick.playerID)
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
            }
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - My picks

    @ViewBuilder
    private func myPicks(draft: Draft, league: League) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let myTeam = league.teams.first(where: { $0.ownerID == app.session?.userID })
        if let myTeam {
            let mine = picks.filter { $0.teamID == myTeam.id }
            if mine.isEmpty {
                Text("You haven't made any picks yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, FFSpace.xl)
            } else {
                VStack(spacing: 0) {
                    ForEach(mine) { p in
                        let player = players[p.playerID]
                        HStack {
                            Text("#\(p.pickNumber)")
                                .font(.ffStatSmall).foregroundStyle(FFColor.accent)
                                .frame(width: 40, alignment: .leading)
                            if let player {
                                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 36)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(player?.name ?? p.playerID)
                                    .font(.ffBody).foregroundStyle(FFColor.textPrimary)
                                HStack(spacing: 6) {
                                    if let player {
                                        PositionPill(position: player.position)
                                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                                    }
                                    if p.autoPick {
                                        Text("• auto").font(.ffCaption).foregroundStyle(FFColor.warning)
                                    }
                                }
                            }
                            .playerLink(p.playerID)
                            Spacer()
                        }
                        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                        .ffHairlineBottom()
                    }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
            }
        } else {
            Text("You don't own a team in this league — spectating.")
                .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, FFSpace.xl)
        }
    }

    // MARK: - Actions

    private func pick(_ player: PlayerSummary) async {
        guard let draft, let league,
              let myTeam = league.teams.first(where: { $0.ownerID == app.session?.userID })
        else { return }
        saving = true; defer { saving = false }
        do {
            let updated = try await app.makePick(
                draftID: draft.id, teamID: myTeam.id, playerID: player.id
            )
            if let updated { self.draft = updated }
            Haptics.success()
            await reload()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func maybeAutoPick(draft: Draft) async {
        if autoPicking { return }
        guard draft.format != .auction else { return }   // auction: settle/nominate paths only
        guard let league else { return }
        autoPicking = true
        defer { autoPicking = false }
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        _ = await app.autoPickIfExpired(draft: draft, league: league, players: players)
        await reload()
    }

    // Called when realtime / reload reports a new current_pick. If the new
    // on-clock team is in auto-pick mode, fire a pick after a small jittered
    // delay so multiple open clients don't all race to make the same call.
    private func maybeAutoPickForAutoTeam() async {
        guard let draft, let league else { return }
        guard draft.format != .auction else { return }   // auction: settle/nominate paths only
        guard draft.status == .live else { return }
        guard let teamID = draft.teamOnClock(forPick: draft.currentPick),
              draft.isOnAutoPick(teamID: teamID) else { return }
        // 250-1500ms jitter to spread out competing clients. The RPC's unique
        // constraint on (draft_id, pick_number) drops late losers harmlessly.
        let jitter = UInt64.random(in: 250_000_000 ... 1_500_000_000)
        try? await Task.sleep(nanoseconds: jitter)
        // Re-read draft in case someone else already picked.
        let fresh = await app.draft(leagueID: league.id) ?? draft
        guard fresh.currentPick == draft.currentPick,
              fresh.teamOnClock(forPick: fresh.currentPick) == teamID else { return }
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        if let updated = await app.autoPickForOnClockAutoTeam(
            draft: fresh, league: league, players: players
        ) {
            self.draft = updated
            await reload()
        }
    }

    private func toggleAutoPick(team: FantasyTeam, enabled: Bool) async {
        guard let draft else { return }
        do {
            if let updated = try await app.setAutoPick(
                draftID: draft.id, teamID: team.id, enabled: enabled
            ) {
                self.draft = updated
                // If we just turned auto on for the team currently on the
                // clock, fire a pick immediately.
                if enabled, updated.teamOnClock(forPick: updated.currentPick) == team.id {
                    Task { await maybeAutoPickForAutoTeam() }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // Commissioner makes a manual pick on behalf of `team`. Used in the
    // Testing Environment to walk through bot picks one by one.
    private func pickOnBehalf(of team: FantasyTeam, player: PlayerSummary) async {
        guard let draft else { return }
        saving = true; defer { saving = false }
        do {
            let updated = try await app.makePick(
                draftID: draft.id, teamID: team.id, playerID: player.id
            )
            if let updated { self.draft = updated }
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Bits

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
            TextField("", text: $query,
                      prompt: Text("Search players").foregroundColor(FFColor.textTertiary))
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FFColor.textTertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, FFSpace.m)
        .padding(.vertical, 10)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func formatADP(_ adp: Double) -> String {
        // FFC reports fractional ADP (e.g. 12.4). One decimal is enough.
        String(format: "%.1f", adp)
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 86400 { return "\(s / 86400)d \((s % 86400) / 3600)h" }
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        if s >= 60   { return String(format: "%dm %02ds", s / 60,   s % 60) }
        return "\(s)s"
    }
}

// Amount picker for putting a player up for auction. The opening bid is the
// nominator's first bid, capped at their max.
struct NominationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let player: PlayerSummary
    let maxBid: Int
    let onConfirm: (Int) -> Void

    @State private var amount: Int = 1

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: FFSpace.xl) {
                    HStack(spacing: FFSpace.m) {
                        PlayerAvatar(url: player.headshotURL,
                                     fallback: player.name.initialsFromName, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.name)
                                .font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                            HStack(spacing: 6) {
                                PositionPill(position: player.position)
                                Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                            }
                        }
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        Text("OPENING BID").ffEyebrow()
                        Stepper(value: $amount, in: 1...max(1, maxBid)) {
                            HStack {
                                Text("$\(amount)")
                                    .font(.ffStatMedium)
                                    .foregroundStyle(FFColor.accent)
                                Spacer()
                                Text("max $\(maxBid)")
                                    .font(.ffCaption)
                                    .foregroundStyle(FFColor.textTertiary)
                            }
                        }
                        .padding(FFSpace.m)
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                    }
                    Button {
                        onConfirm(amount)
                        dismiss()
                    } label: {
                        Text("Nominate at $\(amount)")
                    }
                    .ffPrimaryButton(disabled: maxBid < 1)
                    .disabled(maxBid < 1)
                    Spacer()
                }
                .padding(FFSpace.l)
            }
            .navigationTitle("Nominate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
