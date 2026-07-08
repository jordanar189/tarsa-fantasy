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
    @State private var assets: [String: DraftPickAsset] = [:]
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
    // My side of a multi trade (nil for 2-party trades or non-participants).
    private var myParticipant: TradeParticipant? {
        guard trade.isMulti, let myID = myTeam?.id else { return nil }
        return trade.participants.first(where: { $0.teamID == myID })
    }
    private var canVote: Bool {
        guard trade.status == .voting, let myID = myTeam?.id else { return false }
        if trade.isMulti {
            return !trade.participants.contains { $0.teamID == myID }
        }
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
                        // The balance gauge is inherently two-sided.
                        if !trade.isMulti { balanceCard }
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
                let hasPicks = !(trade.proposerPickIDs.isEmpty && trade.recipientPickIDs.isEmpty)
                    || trade.participants.contains { !$0.givesPickIDs.isEmpty }
                if hasPicks {
                    assets = Dictionary(uniqueKeysWithValues:
                        await app.pickAssets(leagueID: league.id).map { ($0.id, $0) })
                }
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

    // Each team is valued by what it receives in the swap.
    private var balanceCard: some View {
        TradeBalanceView(
            players: valuationPlayers,
            values: values,
            leftName: proposerTeam?.name ?? "Proposer",
            leftReceives: trade.recipientPlayerIDs,
            rightName: recipientTeam?.name ?? "Recipient",
            rightReceives: trade.proposerPlayerIDs,
            valueRatings: app.selectedLeagueValueMap()
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
        case .pending:
            if trade.isMulti {
                let waiting = trade.participants.filter { $0.acceptedAt == nil }.count
                return "Waiting on \(waiting) of \(trade.participants.count) teams to accept."
            }
            return "Awaiting \(recipientTeam?.name ?? "recipient")'s response."
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
            if trade.isMulti {
                ForEach(Array(trade.participants.enumerated()), id: \.element.id) { idx, part in
                    if idx > 0 { Rectangle().fill(FFColor.border).frame(height: 1) }
                    participantRow(part, players: players)
                }
            } else {
                sideRow(team: proposerTeam, label: "Sends", ids: trade.proposerPlayerIDs,
                        pickIDs: trade.proposerPickIDs, players: players)
                Rectangle().fill(FFColor.border).frame(height: 1)
                sideRow(team: recipientTeam, label: "Sends", ids: trade.recipientPlayerIDs,
                        pickIDs: trade.recipientPickIDs, players: players)
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    // One multi-trade participant: acceptance state, what they send (full
    // rows), and what they get back (compact line).
    private func participantRow(_ part: TradeParticipant, players: [String: Player]) -> some View {
        let team = league.teams.first(where: { $0.id == part.teamID })
        let receives = part.receivesPlayerIDs.map { players[$0]?.name ?? $0 }
            + part.receivesPickIDs.map { assets[$0]?.shortLabel ?? "a pick" }
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                Text(team?.name ?? "—")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                if trade.status == .pending {
                    Image(systemName: part.acceptedAt != nil ? "checkmark.circle.fill" : "clock")
                        .font(.system(size: 13))
                        .foregroundStyle(part.acceptedAt != nil ? FFColor.positive : FFColor.warning)
                }
                Spacer()
                Text("SENDS").ffEyebrow(color: FFColor.textTertiary)
            }
            if part.givesPlayerIDs.isEmpty && part.givesPickIDs.isEmpty {
                Text("Nothing")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            } else {
                ForEach(part.givesPlayerIDs, id: \.self) { pid in
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
                ForEach(part.givesPickIDs, id: \.self) { pickID in
                    HStack(spacing: FFSpace.m) {
                        Image(systemName: "ticket")
                            .font(.system(size: 16))
                            .foregroundStyle(FFColor.accent)
                            .frame(width: 32)
                        Text(pickLabel(pickID))
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                        Spacer()
                    }
                }
            }
            if !receives.isEmpty {
                Text("Gets: \(receives.joined(separator: ", "))")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
        }
        .padding(FFSpace.l)
    }

    private func sideRow(team: FantasyTeam?, label: String, ids: [String],
                         pickIDs: [String] = [], players: [String: Player]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(team?.name ?? "—")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text(label.uppercased()).ffEyebrow(color: FFColor.textTertiary)
            }
            if ids.isEmpty && pickIDs.isEmpty {
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
                ForEach(pickIDs, id: \.self) { pickID in
                    HStack(spacing: FFSpace.m) {
                        Image(systemName: "ticket")
                            .font(.system(size: 16))
                            .foregroundStyle(FFColor.accent)
                            .frame(width: 32)
                        Text(pickLabel(pickID))
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                        Spacer()
                    }
                }
            }
        }
        .padding(FFSpace.l)
    }

    private func pickLabel(_ pickID: String) -> String {
        guard let asset = assets[pickID] else { return "Draft pick" }
        if asset.originalTeamID != asset.ownerTeamID,
           let origin = league.teams.first(where: { $0.id == asset.originalTeamID }) {
            return "\(asset.shortLabel) (via \(origin.name))"
        }
        return asset.shortLabel
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
        if let mine = myParticipant, !isProposer, trade.status == .pending {
            if mine.acceptedAt == nil {
                VStack(spacing: FFSpace.s) {
                    Button { Task { await act { try await app.acceptTrade(trade.id) } } } label: {
                        Text("Accept")
                    }.ffPrimaryButton().disabled(saving)
                    Button { Task { await act { try await app.rejectTrade(trade.id) } } } label: {
                        Text("Reject")
                    }.ffSecondaryButton().disabled(saving)
                }
            } else {
                VStack(spacing: FFSpace.s) {
                    Text("You're in — waiting on the other teams.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { Task { await act { try await app.rejectTrade(trade.id) } } } label: {
                        Text("Back out")
                    }.ffSecondaryButton().disabled(saving)
                }
            }
        }
        if !trade.isMulti && isRecipient && trade.status == .pending {
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
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
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
