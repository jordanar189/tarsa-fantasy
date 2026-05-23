import SwiftUI

// Waivers section inside LeagueDetailView. Three sub-tabs:
//
//   Free agents  – players not on any roster; tap to add (or claim if the
//                  player was recently dropped and is still inside the waiver
//                  period).
//   Waivers      – the signed-in user's pending claims, plus a "recently
//                  dropped" list to claim from.
//   Activity     – chronological transaction log; if the user is the
//                  commissioner and approval is on, pending items can be
//                  approved or rejected inline.
struct WaiversView: View {
    @Environment(AppState.self) private var app
    let league: League
    let onLeagueUpdate: (League) -> Void

    enum SubTab: String, CaseIterable, Identifiable, Hashable {
        case freeAgents = "Free agents"
        case waivers    = "Waivers"
        case trades     = "Trades"
        case activity   = "Activity"
        var id: String { rawValue }
    }

    @State private var subTab: SubTab = .freeAgents
    @State private var query: String = ""
    @State private var position: Position = .all
    @State private var dropped: [DroppedPlayer] = []
    @State private var claims: [WaiverClaim] = []
    @State private var transactions: [LeagueTransaction] = []
    @State private var loading: Bool = false
    @State private var refreshTick: Int = 0
    @State private var claimContext: ClaimContext? = nil
    @State private var error: String? = nil

    // MARK: - Body

    var body: some View {
        VStack(spacing: FFSpace.l) {
            SegmentedTabPicker(items: SubTab.allCases, selection: $subTab) {
                Text($0.rawValue)
            }
            if let error {
                Text(error)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch subTab {
            case .freeAgents: freeAgentsSection
            case .waivers:    waiversSection
            case .trades:
                TradesView(league: league) { updated in onLeagueUpdate(updated) }
            case .activity:   activitySection
            }
        }
        .task(id: league.id) { await reload() }
        .task(id: refreshTick) { await reload() }
        .sheet(item: $claimContext) { ctx in
            WaiverClaimSheet(
                league: league, team: ctx.team,
                addPlayer: ctx.addPlayer,
                isOnWaivers: ctx.isOnWaivers,
                waiverUntil: ctx.waiverUntil
            ) { updated in
                if let updated { onLeagueUpdate(updated) }
                refreshTick &+= 1
            }
        }
    }

    private var myTeam: FantasyTeam? {
        guard let uid = app.session?.userID else { return nil }
        return league.teams.first(where: { $0.ownerID == uid })
    }

    private var isCommissioner: Bool {
        guard let uid = app.session?.userID else { return false }
        return league.creatorID == uid
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        async let d = app.droppedPlayers(leagueID: league.id)
        async let c = app.waiverClaims(leagueID: league.id)
        async let t = app.transactions(leagueID: league.id)
        dropped      = await d
        claims       = await c
        transactions = await t
    }

    // MARK: - Free agents

    @ViewBuilder
    private var freeAgentsSection: some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let week    = Fantasy.currentWeek(players: players)
        let freeIDs = Fantasy.freeAgents(league: league, players: players)
        let waiverMap = Dictionary(uniqueKeysWithValues: dropped.map { ($0.playerID, $0) })

        VStack(spacing: FFSpace.s) {
            searchBar
            ChipRow(items: Position.allCases, selection: $position) { Text($0.label) }

            let candidates = Fantasy.search(
                players: players, query: query, position: position,
                scoring: league.scoring, limit: 0
            ).filter { freeIDs.contains($0.id) }

            if candidates.isEmpty {
                emptyHint("No free agents match.")
            } else {
                let visible = Array(candidates.prefix(200))
                VStack(spacing: 0) {
                    ForEach(visible) { row in
                        freeAgentRow(
                            row,
                            drop: waiverMap[row.id],
                            locked: Fantasy.isPlayerLocked(playerID: row.id, week: week, players: players)
                        )
                    }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
                .prefetchAvatars(urls: visible.map(\.headshotURL))
            }
        }
    }

    private func freeAgentRow(_ row: PlayerSummary, drop: DroppedPlayer?, locked: Bool) -> some View {
        let onWaivers = drop?.isOnWaivers == true
        return HStack(spacing: FFSpace.m) {
            PlayerAvatar(url: row.headshotURL, fallback: row.name.initialsFromName, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    PositionPill(position: row.position)
                    Text(row.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    if locked {
                        FFPill { Text("LOCKED") }.foregroundStyle(FFColor.warning)
                    } else if onWaivers, let d = drop {
                        Text("• On waivers \(d.waiverUntil.shortRelative)")
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.accent)
                    }
                }
            }
            .playerLink(row.id)
            Spacer()
            Text(row.points.fpString)
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.textSecondary)
            actionButton(label: onWaivers ? "Claim" : "Add", disabled: locked || myTeam == nil) {
                guard let team = myTeam else { return }
                claimContext = ClaimContext(
                    team: team, addPlayer: row,
                    isOnWaivers: onWaivers, waiverUntil: drop?.waiverUntil
                )
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - Waivers

    @ViewBuilder
    private var waiversSection: some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let myID = myTeam?.id
        let myClaims = claims.filter { $0.teamID == myID && $0.status == .pending }
            .sorted { $0.teamPriority < $1.teamPriority }
        let activeDrops = dropped
            .filter { $0.isOnWaivers }
            .sorted { $0.waiverUntil < $1.waiverUntil }

        VStack(alignment: .leading, spacing: FFSpace.l) {
            // Priority callout — show me my position in the league-wide order.
            priorityCallout

            // My pending claims.
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("Your pending claims").ffEyebrow()
                if myClaims.isEmpty {
                    emptyHint("You haven't submitted any waiver claims.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(myClaims.enumerated()), id: \.element.id) { idx, claim in
                            myClaimRow(claim, players: players, position: idx + 1, total: myClaims.count)
                        }
                    }
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.m)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )
                    .padding(.bottom, FFSpace.xs)
                    Text("Higher-priority claims are processed first. Long-press to reorder soon.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }

            // Players currently on waivers (anyone can claim).
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("On waivers").ffEyebrow()
                if activeDrops.isEmpty {
                    emptyHint("No players are on waivers right now.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(activeDrops) { d in
                            droppedRow(d, players: players)
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
    }

    @ViewBuilder
    private var priorityCallout: some View {
        let myID = myTeam?.id
        let idx  = league.waiverPriority.firstIndex(of: myID ?? "")
        let processLabel = "\(league.waiverSettings.processDayLabel) "
            + String(format: "%02d:00 UTC", league.waiverSettings.processHour)

        HStack(spacing: FFSpace.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR PRIORITY").ffEyebrow(color: FFColor.textTertiary)
                Text(idx.map { "#\($0 + 1) of \(league.waiverPriority.count)" } ?? "—")
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.textPrimary)
            }
            divider
            VStack(alignment: .leading, spacing: 4) {
                Text("PROCESSES").ffEyebrow(color: FFColor.textTertiary)
                Text(processLabel)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textPrimary)
            }
            Spacer()
        }
        .ffCard()
    }

    private var divider: some View {
        Rectangle().fill(FFColor.border).frame(width: 1, height: 28)
    }

    private func myClaimRow(_ claim: WaiverClaim, players: [String: Player],
                            position: Int, total: Int) -> some View {
        let add  = players[claim.addPlayerID]
        let drop = claim.dropPlayerID.flatMap { players[$0] }
        return HStack(spacing: FFSpace.m) {
            Text("#\(position)")
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.accent)
                .frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(add?.name ?? claim.addPlayerID).font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    if let add { PositionPill(position: add.position); Text(add.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary) }
                    if let drop {
                        Text("• drop")
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textTertiary)
                        Text(drop.name).font(.ffCaption).foregroundStyle(FFColor.textSecondary).lineLimit(1)
                    }
                }
            }
            .playerLink(claim.addPlayerID)
            Spacer()
            Button {
                Task {
                    try? await app.cancelWaiverClaim(claim.id)
                    refreshTick &+= 1
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(FFColor.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func droppedRow(_ d: DroppedPlayer, players: [String: Player]) -> some View {
        let p = players[d.playerID]
        let summary = p.map { Fantasy.summary($0, scoring: league.scoring) }
        let week = Fantasy.currentWeek(players: players)
        let locked = Fantasy.isPlayerLocked(playerID: d.playerID, week: week, players: players)
        return HStack(spacing: FFSpace.m) {
            PlayerAvatar(url: summary?.headshotURL ?? "", fallback: (summary?.name ?? "?").initialsFromName, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary?.name ?? d.playerID).font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    if let summary {
                        PositionPill(position: summary.position)
                        Text(summary.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    }
                    Text("• clears \(d.waiverUntil.shortRelative)")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.accent)
                }
            }
            .playerLink(d.playerID)
            Spacer()
            actionButton(label: "Claim", disabled: locked || myTeam == nil) {
                guard let team = myTeam, let summary else { return }
                claimContext = ClaimContext(
                    team: team, addPlayer: summary,
                    isOnWaivers: true, waiverUntil: d.waiverUntil
                )
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - Activity

    @ViewBuilder
    private var activitySection: some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        if transactions.isEmpty {
            emptyHint("No transactions yet.")
        } else {
            VStack(spacing: 0) {
                ForEach(transactions) { tx in
                    transactionRow(tx, players: players)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func transactionRow(_ tx: LeagueTransaction, players: [String: Player]) -> some View {
        let add  = tx.addPlayerID.flatMap  { players[$0] }
        let drop = tx.dropPlayerID.flatMap { players[$0] }
        let pending = tx.status == .pendingApproval

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: FFSpace.s) {
                Text(tx.teamName).font(.ffHeadline).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                Spacer()
                statusPill(tx.status)
                Text(tx.createdAt.shortRelative)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let add {
                    Text("＋ Added \(add.name) (\(add.position) · \(add.team))")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.positive)
                }
                if let drop {
                    Text("− Dropped \(drop.name) (\(drop.position) · \(drop.team))")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                }
                if add == nil && drop == nil {
                    Text(tx.kind.label).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
            if let note = tx.note, !note.isEmpty {
                Text(note).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            }
            if pending && isCommissioner {
                HStack(spacing: FFSpace.s) {
                    Button {
                        Task {
                            do {
                                let updated = try await app.approveTransaction(tx.id)
                                if let updated { onLeagueUpdate(updated) }
                                refreshTick &+= 1
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    } label: {
                        Text("Approve")
                            .font(.ffCaption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(FFColor.accent, in: Capsule())
                            .foregroundStyle(FFColor.bg)
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task {
                            do {
                                try await app.rejectTransaction(tx.id, note: nil)
                                refreshTick &+= 1
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    } label: {
                        Text("Reject")
                            .font(.ffCaption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .overlay(Capsule().strokeBorder(FFColor.border, lineWidth: 1))
                            .foregroundStyle(FFColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    private func statusPill(_ status: TransactionStatus) -> some View {
        let color: Color
        switch status {
        case .completed:       color = FFColor.positive
        case .pendingApproval: color = FFColor.warning
        case .rejected:        color = FFColor.negative
        case .failed:          color = FFColor.negative
        }
        return Text(status.label.uppercased())
            .font(.ffMicro)
            .tracking(0.8)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
            .foregroundStyle(color)
    }

    // MARK: - Bits

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
            TextField("", text: $query, prompt: Text("Search players").foregroundColor(FFColor.textTertiary))
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

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.ffBody)
            .foregroundStyle(FFColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, FFSpace.xl)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }

    private func actionButton(label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.ffCaption.bold())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(disabled ? FFColor.surfaceElevated : FFColor.accent, in: Capsule())
                .foregroundStyle(disabled ? FFColor.textTertiary : FFColor.bg)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    struct ClaimContext: Identifiable {
        let team: FantasyTeam
        let addPlayer: PlayerSummary
        let isOnWaivers: Bool
        let waiverUntil: Date?
        var id: String { addPlayer.id }
    }
}

// MARK: - Date helper

extension Date {
    var shortRelative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: self, relativeTo: Date())
    }
}
