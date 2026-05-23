import SwiftUI

// Detail modal for a single trade. Header shows current status with a
// locked-player ETA when status = pendingExecution. Action buttons gate on
// the viewer's role: recipient sees Accept/Reject/Counter, proposer sees
// Cancel, eligible league members see vote buttons during the vote window,
// the commissioner sees Approve/Reject when status = pendingApproval.
struct TradeDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let trade: Trade
    let onChange: (Trade?) -> Void
    let onCounter: (Trade) -> Void

    @State private var votes: [TradeVote] = []
    @State private var saving: Bool = false
    @State private var error: String? = nil
    @State private var values: [String: Double] = [:]
    @State private var valuationPlayers: [String: Player] = [:]

    private var myTeam: FantasyTeam? {
        guard let uid = app.session?.userID else { return nil }
        return league.teams.first(where: { $0.ownerID == uid })
    }

    private var isProposer:  Bool { trade.proposerTeamID == myTeam?.id }
    private var isRecipient: Bool { trade.recipientTeamID == myTeam?.id }
    private var isCommish:   Bool { league.creatorID == app.session?.userID }
    private var canVote: Bool {
        guard trade.status == .voting, let myID = myTeam?.id else { return false }
        return myID != trade.proposerTeamID && myID != trade.recipientTeamID
    }

    private var proposerTeam:  FantasyTeam? { league.teams.first(where: { $0.id == trade.proposerTeamID }) }
    private var recipientTeam: FantasyTeam? { league.teams.first(where: { $0.id == trade.recipientTeamID }) }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.l) {
                        statusBanner
                        sidesCard
                        balanceCard
                        if let note = trade.note, !note.isEmpty {
                            Text("“\(note)”")
                                .font(.ffBody.italic())
                                .foregroundStyle(FFColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(FFSpace.m)
                                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                        }
                        if trade.status == .voting { votingPanel }
                        actionButtons
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
            .navigationTitle("Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
            .task(id: trade.id) {
                await reloadVotes()
                await app.ensureProjectedSnapshot(season: league.season)
                let snapshot = Fantasy.playersFor(league: league, snapshot: app.displayPlayers(season: league.season))
                valuationPlayers = snapshot
                values = Fantasy.tradeValues(
                    players: snapshot, scoring: league.scoring,
                    settings: league.scoringSettings, config: league.rosterConfig,
                    teamCount: league.teams.count
                )
            }
        }
        .hostsPlayerProfileSheet()
    }

    // Each team is valued by what it receives in the swap.
    private var balanceCard: some View {
        TradeBalanceView(
            players: valuationPlayers,
            values: values,
            leftName: proposerTeam?.name ?? "Proposer",
            leftReceives: trade.recipientPlayerIDs,
            rightName: recipientTeam?.name ?? "Recipient",
            rightReceives: trade.proposerPlayerIDs
        )
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(trade.status.label.uppercased())
                    .ffEyebrow(color: statusColor)
                Spacer()
                if trade.status == .voting, let ends = trade.votingEndsAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Closes \(ends.shortRelative)")
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                } else {
                    Text(trade.createdAt.shortRelative)
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Text(statusDescription)
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
            if trade.status == .pendingExecution {
                lockedPlayersHint
            }
            if let reason = trade.failureReason, !reason.isEmpty {
                Text(reason)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.warning)
            }
        }
        .ffCard()
    }

    @ViewBuilder
    private var lockedPlayersHint: some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let week = Fantasy.currentWeek(players: players)
        let all = trade.proposerPlayerIDs + trade.recipientPlayerIDs
        let locked = all.filter { Fantasy.isPlayerLocked(playerID: $0, week: week, players: players) }
        if !locked.isEmpty {
            Text("Waiting on \(locked.count) player\(locked.count == 1 ? "" : "s") to finish this week's game before the swap can execute.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.warning)
        } else {
            Text("All players unlocked — the next scheduled tick will execute this trade.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.accent)
        }
    }

    private var statusColor: Color {
        switch trade.status {
        case .pending, .pendingApproval, .pendingExecution: return FFColor.warning
        case .accepted, .voting:    return FFColor.accent
        case .executed:             return FFColor.positive
        case .rejected, .vetoed:    return FFColor.negative
        case .cancelled, .countered: return FFColor.textSecondary
        }
    }

    private var statusDescription: String {
        switch trade.status {
        case .pending:           return "Awaiting \(recipientTeam?.name ?? "recipient")'s response."
        case .accepted:          return "Accepted — being routed to review."
        case .pendingApproval:   return "Waiting for the commissioner to approve."
        case .voting:            return "League members can veto. Majority of other owners required."
        case .pendingExecution:  return "Cleared review. Holding for game locks before swapping rosters."
        case .executed:          return "Rosters swapped on \(trade.executedAt?.shortRelative ?? "—")."
        case .rejected:          return "\(recipientTeam?.name ?? "Recipient") rejected this trade."
        case .cancelled:         return "Proposer cancelled."
        case .countered:         return "A counter-offer was sent in response to this trade."
        case .vetoed:            return "Vetoed."
        }
    }

    private var sidesCard: some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        return VStack(spacing: 0) {
            sideRow(team: proposerTeam, label: "Sends", ids: trade.proposerPlayerIDs, players: players)
            Rectangle().fill(FFColor.border).frame(height: 1)
            sideRow(team: recipientTeam, label: "Sends", ids: trade.recipientPlayerIDs, players: players)
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func sideRow(team: FantasyTeam?, label: String, ids: [String], players: [String: Player]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(team?.name ?? "—")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text(label.uppercased()).ffEyebrow(color: FFColor.textTertiary)
            }
            if ids.isEmpty {
                Text("Nothing")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            } else {
                ForEach(ids, id: \.self) { pid in
                    let p = players[pid]
                    let summary = p.map { Fantasy.summary($0, scoring: league.scoring) }
                    HStack(spacing: FFSpace.m) {
                        PlayerAvatar(url: summary?.headshotURL ?? "",
                                     fallback: (summary?.name ?? "?").initialsFromName, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary?.name ?? pid)
                                .font(.ffBody)
                                .foregroundStyle(FFColor.textPrimary)
                            if let summary {
                                HStack(spacing: 6) {
                                    PositionPill(position: summary.position)
                                    Text(summary.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                                }
                            }
                        }
                        .playerLink(pid)
                        Spacer()
                        Text(summary?.points.fpString ?? "—")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.textSecondary)
                    }
                }
            }
        }
        .padding(FFSpace.l)
    }

    @ViewBuilder
    private var votingPanel: some View {
        let approveCount = votes.filter { $0.vote == "approve" }.count
        let vetoCount    = votes.filter { $0.vote == "veto" }.count
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("LEAGUE VOTE").ffEyebrow()
            HStack(spacing: FFSpace.l) {
                voteTally(label: "Approve", count: approveCount, color: FFColor.positive)
                voteTally(label: "Veto",    count: vetoCount,    color: FFColor.negative)
            }
        }
        .ffCard()
    }

    private func voteTally(label: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
            Text("\(count)").font(.ffStatMedium).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isRecipient && trade.status == .pending {
            VStack(spacing: FFSpace.s) {
                Button { Task { await act { try await app.acceptTrade(trade.id) } } } label: {
                    Text("Accept")
                }.ffPrimaryButton().disabled(saving)
                HStack(spacing: FFSpace.s) {
                    Button { Task { await act { try await app.rejectTrade(trade.id) } } } label: {
                        Text("Reject")
                    }.ffSecondaryButton().disabled(saving)
                    Button { onCounter(trade) } label: {
                        Text("Counter")
                    }.ffSecondaryButton().disabled(saving)
                }
            }
        }
        if isProposer && trade.status == .pending {
            Button { Task { await act { try await app.cancelTrade(trade.id) } } } label: {
                Text("Cancel trade")
            }.ffSecondaryButton().disabled(saving)
        }
        if isCommish && trade.status == .pendingApproval {
            HStack(spacing: FFSpace.s) {
                Button { Task { await commishAct(approve: true) } } label: {
                    Text("Approve")
                }.ffPrimaryButton().disabled(saving)
                Button { Task { await commishAct(approve: false) } } label: {
                    Text("Reject")
                }.ffSecondaryButton().disabled(saving)
            }
        }
        if canVote {
            HStack(spacing: FFSpace.s) {
                Button { Task { await voteAct("approve") } } label: {
                    Text("Vote approve")
                }.ffSecondaryButton().disabled(saving)
                Button { Task { await voteAct("veto") } } label: {
                    Text("Vote veto")
                }.ffPrimaryButton().disabled(saving)
            }
        }
    }

    private func act(_ op: () async throws -> Trade?) async {
        saving = true; defer { saving = false }
        do {
            let updated = try await op()
            onChange(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func commishAct(approve: Bool) async {
        await act { try await app.commishResolveTrade(trade.id, approve: approve, note: nil) }
    }

    private func voteAct(_ vote: String) async {
        saving = true; defer { saving = false }
        do {
            let updated = try await app.voteTrade(trade.id, vote: vote)
            onChange(updated)
            await reloadVotes()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reloadVotes() async {
        votes = await app.tradeVotes(tradeID: trade.id)
    }
}
