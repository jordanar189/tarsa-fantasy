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
    @State private var loading: Bool = false
    @State private var refreshTick: Int = 0
    @State private var showingPropose: Bool = false
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
        let incoming = trades.filter { $0.status == .pending && $0.recipientTeamID == myID }
        let outgoing = trades.filter { $0.status == .pending && $0.proposerTeamID == myID }
        let underReview = trades.filter {
            ($0.status == .pendingApproval || $0.status == .voting || $0.status == .pendingExecution)
            && ($0.proposerTeamID == myID || $0.recipientTeamID == myID || isCommissioner
                || $0.status == .voting)
        }
        let recent = trades.filter { !$0.status.isOpen }.prefix(15)

        if trades.isEmpty {
            emptyHint(loading ? "Loading trades…" : "No trades yet. Propose one to get things moving.")
        } else {
            VStack(alignment: .leading, spacing: FFSpace.xl) {
                section(title: "Incoming", count: incoming.count, items: incoming)
                section(title: "Outgoing", count: outgoing.count, items: outgoing)
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

        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                Text(proposer?.name ?? "?").font(.ffCaption.bold()).foregroundStyle(FFColor.textPrimary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
                Text(recipient?.name ?? "?").font(.ffCaption.bold()).foregroundStyle(FFColor.textPrimary)
                Spacer()
                statusBadge(trade.status)
            }
            HStack(alignment: .top, spacing: FFSpace.s) {
                sideColumn(label: "Sends", ids: trade.proposerPlayerIDs, players: players)
                Rectangle().fill(FFColor.border).frame(width: 1)
                sideColumn(label: "Receives", ids: trade.recipientPlayerIDs, players: players)
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

    private func sideColumn(label: String, ids: [String], players: [String: Player]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            if ids.isEmpty {
                Text("—").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            } else {
                ForEach(ids, id: \.self) { pid in
                    let p = players[pid]
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}
