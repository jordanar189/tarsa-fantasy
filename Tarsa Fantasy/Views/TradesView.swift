import SwiftUI

// Trades sub-section rendered inside WaiversView. Sections:
//   Incoming  – pending trades where the signed-in user is the recipient
//   Outgoing  – pending trades where the user is the proposer
//   Under review – accepted trades waiting on commish approval / league vote
//                  / locked-player unlock
//   Recent    – terminal trades (executed, rejected, cancelled, vetoed)
//
// The Propose Trade button opens ProposeTradeView. Tapping any card opens
// TradeDetailView with the role-appropriate actions.
struct TradesView: View {
    @Environment(AppState.self) private var app
    let league: League
    let onLeagueUpdate: (League) -> Void

    @State private var trades: [Trade] = []
    @State private var assets: [String: DraftPickAsset] = [:]
    @State private var loading: Bool = false
    @State private var refreshTick: Int = 0
    @State private var showingPropose: Bool = false
    @State private var showingMultiPropose: Bool = false
    @State private var selectedTrade: Trade? = nil
    @State private var counterOf: Trade? = nil
    @State private var error: String? = nil

    private var myTeam: FantasyTeam? {
        guard let uid = app.session?.userID else { return nil }
        return league.teams.first(where: { $0.ownerID == uid })
    }

    private var isCommissioner: Bool {
        league.creatorID == app.session?.userID
    }

    private var canPropose: Bool {
        guard myTeam != nil else { return false }
        if let deadline = league.tradeSettings.deadline, deadline < Date() { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.l) {
            header
            if let error {
                Text(error)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
        }
        .task(id: league.id) { await reload() }
        .task(id: refreshTick) { await reload() }
        .sheet(isPresented: $showingPropose) {
            if let myTeam {
                ProposeTradeView(league: league, fromTeam: myTeam, counterOf: nil) { _ in
                    refreshTick &+= 1
                }
            }
        }
        .sheet(isPresented: $showingMultiPropose) {
            if let myTeam {
                MultiTradeBuilderView(league: league, fromTeam: myTeam) { _ in
                    refreshTick &+= 1
                }
            }
        }
        .sheet(item: $counterOf) { parent in
            // Recipient counters: their team is the proposer, sides flip.
            if let myTeam {
                ProposeTradeView(league: league, fromTeam: myTeam, counterOf: parent) { _ in
                    refreshTick &+= 1
                }
            }
        }
        .sheet(item: $selectedTrade) { trade in
            TradeDetailView(
                league: league, trade: trade,
                onChange: { _ in refreshTick &+= 1 },
                onCounter: { parent in
                    selectedTrade = nil
                    counterOf = parent
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("Trades").ffEyebrow()
                Spacer()
                deadlineLabel
            }
            Button {
                showingPropose = true
            } label: {
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Propose a trade")
                }
            }
            .ffPrimaryButton(disabled: !canPropose)
            .disabled(!canPropose)
            // 3+ owned teams unlocks the multi-team composer.
            if league.teams.filter({ $0.ownerID != nil }).count >= 3 {
                Button {
                    showingMultiPropose = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Multi-team trade")
                    }
                }
                .ffSecondaryButton()
                .disabled(!canPropose)
            }
            if !canPropose, let deadline = league.tradeSettings.deadline, deadline < Date() {
                Text("Trade deadline passed \(deadline.shortRelative).")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var deadlineLabel: some View {
        if let deadline = league.tradeSettings.deadline {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                Text("Deadline \(deadline.formatted(date: .abbreviated, time: .omitted))")
            }
            .font(.ffMicro)
            .foregroundStyle(deadline < Date() ? FFColor.negative : FFColor.textTertiary)
        }
    }

    @ViewBuilder
    private var content: some View {
        let myID = myTeam?.id
        // Multi trades land in Incoming while my acceptance is still pending.
        let incoming = trades.filter { t in
            guard t.status == .pending else { return false }
            if t.isMulti {
                return t.proposerTeamID != myID
                    && t.participants.contains { $0.teamID == myID && $0.acceptedAt == nil }
            }
            return t.recipientTeamID == myID
        }
        let outgoing = trades.filter { t in
            guard t.status == .pending, t.proposerTeamID == myID else { return false }
            return true
        }
        // Multi trades I've already accepted but others haven't yet.
        let waitingOnOthers = trades.filter { t in
            t.isMulti && t.status == .pending && t.proposerTeamID != myID
                && t.participants.contains { $0.teamID == myID && $0.acceptedAt != nil }
        }
        let underReview = trades.filter { t in
            (t.status == .pendingApproval || t.status == .voting || t.status == .pendingExecution)
            && (t.proposerTeamID == myID || t.recipientTeamID == myID || isCommissioner
                || t.status == .voting
                || t.participants.contains { $0.teamID == myID })
        }
        let recent = trades.filter { !$0.status.isOpen }.prefix(15)

        if trades.isEmpty {
            emptyHint(loading ? "Loading trades…" : "No trades yet. Propose one to get things moving.")
        } else {
            VStack(alignment: .leading, spacing: FFSpace.xl) {
                section(title: "Incoming", count: incoming.count, items: incoming)
                section(title: "Outgoing", count: outgoing.count, items: outgoing)
                section(title: "Waiting on others", count: waitingOnOthers.count, items: waitingOnOthers)
                section(title: "Under review", count: underReview.count, items: underReview)
                section(title: "Recent", count: recent.count, items: Array(recent))
            }
        }
    }

    @ViewBuilder
    private func section(title: String, count: Int, items: [Trade]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                HStack {
                    Text(title).ffEyebrow()
                    if count > 0 {
                        Text("\(count)")
                            .font(.ffMicro)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(FFColor.accent, in: Capsule())
                            .foregroundStyle(FFColor.bg)
                    }
                    Spacer()
                }
                VStack(spacing: FFSpace.s) {
                    ForEach(items) { trade in
                        tradeCard(trade)
                            .onTapGesture { selectedTrade = trade }
                    }
                }
            }
        }
    }

    private func tradeCard(_ trade: Trade) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let proposer = league.teams.first(where: { $0.id == trade.proposerTeamID })
        let recipient = league.teams.first(where: { $0.id == trade.recipientTeamID })
        let mine = trade.proposerTeamID == myTeam?.id || trade.recipientTeamID == myTeam?.id
            || trade.participants.contains { $0.teamID == myTeam?.id }

        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                if trade.isMulti {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FFColor.accent)
                    Text("\(trade.participants.count)-team trade")
                        .font(.ffCaption.bold()).foregroundStyle(FFColor.textPrimary)
                    if trade.status == .pending {
                        Text("\(trade.acceptedCount)/\(trade.participants.count) in")
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                } else {
                    Text(proposer?.name ?? "?").font(.ffCaption.bold()).foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                    Text(recipient?.name ?? "?").font(.ffCaption.bold()).foregroundStyle(FFColor.textPrimary)
                }
                Spacer()
                statusBadge(trade.status)
            }
            if trade.isMulti {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    ForEach(trade.participants) { part in
                        multiParticipantRow(part, players: players)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: FFSpace.s) {
                    sideColumn(label: "Sends", ids: trade.proposerPlayerIDs,
                               pickIDs: trade.proposerPickIDs, players: players)
                    Rectangle().fill(FFColor.border).frame(width: 1)
                    sideColumn(label: "Receives", ids: trade.recipientPlayerIDs,
                               pickIDs: trade.recipientPickIDs, players: players)
                }
            }
            if let note = trade.note, !note.isEmpty {
                Text("“\(note)”")
                    .font(.ffCaption.italic())
                    .foregroundStyle(FFColor.textSecondary)
            }
            HStack {
                Text(trade.createdAt.shortRelative)
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
                Spacer()
                if let reason = trade.failureReason, !reason.isEmpty {
                    Text(reason).font(.ffMicro).foregroundStyle(FFColor.warning).lineLimit(1)
                }
            }
        }
        .ffCard()
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(mine && trade.status.isOpen ? FFColor.accent.opacity(0.4) : Color.clear,
                              lineWidth: 1)
        )
    }

    // Compact one-liner per multi-trade participant: name, gives, acceptance.
    private func multiParticipantRow(_ part: TradeParticipant, players: [String: Player]) -> some View {
        let team = league.teams.first(where: { $0.id == part.teamID })
        let gives = part.givesPlayerIDs.map { players[$0]?.name ?? $0 }
            + part.givesPickIDs.map { assets[$0]?.shortLabel ?? "Pick" }
        return HStack(alignment: .top, spacing: FFSpace.s) {
            Image(systemName: part.acceptedAt != nil ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(part.acceptedAt != nil ? FFColor.positive : FFColor.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(team?.name ?? "?")
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.textPrimary)
                Text(gives.isEmpty ? "sends nothing" : "sends \(gives.joined(separator: ", "))")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private func sideColumn(label: String, ids: [String], pickIDs: [String] = [],
                            players: [String: Player]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            if ids.isEmpty && pickIDs.isEmpty {
                Text("—").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            } else {
                ForEach(ids, id: \.self) { pid in
                    let p = players[pid]
                    // The card's tap opens the trade detail; the player row is
                    // a profile link (deepest gesture wins).
                    HStack(spacing: 4) {
                        if let p {
                            PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 24)
                            PositionPill(position: p.position)
                        }
                        Text(p?.name ?? pid)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                    }
                    .playerLink(pid)
                }
                ForEach(pickIDs, id: \.self) { pickID in
                    HStack(spacing: 4) {
                        Image(systemName: "ticket")
                            .font(.system(size: 12))
                            .foregroundStyle(FFColor.accent)
                        Text(pickLabel(pickID))
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickLabel(_ pickID: String) -> String {
        guard let asset = assets[pickID] else { return "Draft pick" }
        if asset.originalTeamID != asset.ownerTeamID,
           let origin = league.teams.first(where: { $0.id == asset.originalTeamID }) {
            return "\(asset.shortLabel) (via \(origin.name))"
        }
        return asset.shortLabel
    }

    private func statusBadge(_ s: TradeStatus) -> some View {
        let color: Color
        switch s {
        case .pending:           color = FFColor.warning
        case .accepted:          color = FFColor.accent
        case .pendingApproval:   color = FFColor.warning
        case .voting:            color = FFColor.accent
        case .pendingExecution:  color = FFColor.warning
        case .executed:          color = FFColor.positive
        case .rejected:          color = FFColor.negative
        case .cancelled:         color = FFColor.textTertiary
        case .countered:         color = FFColor.textSecondary
        case .vetoed:            color = FFColor.negative
        }
        return Text(s.label.uppercased())
            .font(.ffMicro).tracking(0.7)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
            .foregroundStyle(color)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.ffBody)
            .foregroundStyle(FFColor.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, FFSpace.xl)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }

    private func reload() async {
        loading = true; defer { loading = false }
        trades = await app.trades(leagueID: league.id)
        assets = Dictionary(uniqueKeysWithValues:
            await app.pickAssets(leagueID: league.id).map { ($0.id, $0) })
        // Trades changed (or may have) — keep the Moves tab badge honest.
        await app.refreshMovesBadge()
    }
}
