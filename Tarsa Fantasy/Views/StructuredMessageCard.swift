import SwiftUI

// Renders a structured chat card — poll, pick'em, or trade block — inside the
// league chat transcript. Each kind has a distinct layout:
//   poll       : tap options (single or multi-select), live tallies, optional
//                deadline, optional member-added options, tap "Who voted" to
//                reveal names.
//   pickem     : one row per real NFL game; tap a team to call the winner.
//   tradeblock : the poster's players on offer plus the players they're after.
// Selections are stored in `responses` (one row per user per slot); tapping
// calls `onRespond(slot, choice)` — a nil choice clears that slot.
struct StructuredMessageCard: View {
    let message: LeagueMessage
    let responses: [MessageResponse]
    let myUserID: String?
    let nameFor: (String) -> String
    let onRespond: (_ slot: Int, _ choice: Int?) -> Void
    let onAddOption: () -> Void

    @State private var showVoters = false

    private var payload: ChatPayload { message.payload ?? ChatPayload() }

    private var closesAt: Date? { payload.closesAt.map { Date(timeIntervalSince1970: $0) } }
    private var isClosed: Bool { closesAt.map { $0 <= Date() } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            header
            switch message.kind {
            case .poll:       pollCard
            case .pickem:     pickemCard
            case .tradeblock: tradeBlockCard
            case .text:       EmptyView()
            }
        }
        .padding(FFSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: FFSpace.xs) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(eyebrow)
                .font(.ffMicro)
                .tracking(0.8)
            Spacer(minLength: FFSpace.s)
            deadlineBadge
        }
        .foregroundStyle(FFColor.accent)
    }

    private var icon: String {
        switch message.kind {
        case .poll:       return "chart.bar.fill"
        case .pickem:     return "football.fill"
        case .tradeblock: return "arrow.left.arrow.right"
        case .text:       return "bubble.left"
        }
    }

    private var eyebrow: String {
        switch message.kind {
        case .poll:       return "POLL"
        case .pickem:     return "PICK 'EM"
        case .tradeblock: return "ON THE BLOCK"
        case .text:       return ""
        }
    }

    @ViewBuilder
    private var deadlineBadge: some View {
        if message.kind == .poll || message.kind == .pickem {
            if isClosed {
                Text("CLOSED")
                    .font(.ffMicro)
                    .tracking(0.8)
                    .foregroundStyle(FFColor.textTertiary)
            } else if let closesAt {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .bold))
                    Text(closesAt, style: .relative)
                        .font(.ffMicro)
                }
                .foregroundStyle(FFColor.textTertiary)
            }
        }
    }

    // MARK: - Poll

    private var options: [String] { payload.options ?? [] }
    private var isMulti: Bool { payload.allowMultiple == true }

    private var mySelections: Set<Int> {
        guard let me = myUserID else { return [] }
        return Set(responses.filter { $0.userID == me }.map(\.choice))
    }

    private var voterCount: Int { Set(responses.map(\.userID)).count }

    private func pollCount(_ i: Int) -> Int {
        responses.reduce(0) { $0 + ($1.choice == i ? 1 : 0) }
    }

    private var pollCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            if let question = payload.question, !question.isEmpty {
                Text(question)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    pollRow(index: index, label: option)
                }
            }
            if payload.allowAddOptions == true && !isClosed {
                Button(action: onAddOption) {
                    Label("Add option", systemImage: "plus.circle")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.accent)
                }
                .buttonStyle(.plain)
            }
            pollFooter
        }
    }

    @ViewBuilder
    private func pollRow(index: Int, label: String) -> some View {
        let c = pollCount(index)
        let fraction = voterCount > 0 ? Double(c) / Double(voterCount) : 0
        let isMine = mySelections.contains(index)

        VStack(alignment: .leading, spacing: 4) {
            Button { togglePoll(index) } label: {
                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: FFRadius.s)
                            .fill(isMine ? FFColor.accentSoft : FFColor.accent.opacity(0.10))
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                    HStack(spacing: FFSpace.s) {
                        if isMulti {
                            Image(systemName: isMine ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isMine ? FFColor.accent : FFColor.textTertiary)
                        }
                        Text(label)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: FFSpace.s)
                        if !isMulti && isMine {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(FFColor.accent)
                        }
                        Text("\(c)")
                            .font(.ffCaption.bold())
                            .foregroundStyle(FFColor.textSecondary)
                            .frame(minWidth: 16, alignment: .trailing)
                    }
                    .padding(.horizontal, FFSpace.s)
                    .padding(.vertical, FFSpace.s)
                }
                .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.s)
                        .strokeBorder(isMine ? FFColor.accent.opacity(0.6) : FFColor.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isClosed)

            if showVoters {
                voterList(for: responses.filter { $0.choice == index })
            }
        }
    }

    @ViewBuilder
    private func voterList(for rows: [MessageResponse]) -> some View {
        if rows.isEmpty {
            Text("No votes yet")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
                .padding(.leading, FFSpace.s)
        } else {
            Text(rows.map { nameFor($0.userID) }.joined(separator: ", "))
                .font(.ffMicro)
                .foregroundStyle(FFColor.textSecondary)
                .padding(.leading, FFSpace.s)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pollFooter: some View {
        HStack(spacing: FFSpace.s) {
            Text(voterCount == 1 ? "1 voted" : "\(voterCount) voted")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
            Text(isMulti ? "· Pick any" : "· Pick one")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
            Spacer(minLength: FFSpace.s)
            Button { showVoters.toggle() } label: {
                Text(showVoters ? "Hide voters" : "Who voted")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func togglePoll(_ i: Int) {
        if isMulti {
            onRespond(i, mySelections.contains(i) ? nil : i)
        } else {
            onRespond(0, mySelections.contains(i) ? nil : i)
        }
    }

    // MARK: - Pick'em

    private var games: [PickGame] { payload.games ?? [] }

    private func myPick(_ slot: Int) -> Int? {
        guard let me = myUserID else { return nil }
        return responses.first { $0.userID == me && $0.slot == slot }?.choice
    }

    private func pickCount(slot: Int, side: Int) -> Int {
        responses.reduce(0) { $0 + (($1.slot == slot && $1.choice == side) ? 1 : 0) }
    }

    private func kickoffPassed(_ g: PickGame) -> Bool {
        g.kickoff.map { Date(timeIntervalSince1970: $0) <= Date() } ?? false
    }

    private var pickemCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            let title = payload.question?.isEmpty == false
                ? payload.question!
                : (games.first.map { "Week \($0.week) picks" } ?? "Pick 'em")
            Text(title)
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                    gameRow(slot: index, game: game)
                }
            }
            pickemFooter
        }
    }

    private func gameRow(slot: Int, game: PickGame) -> some View {
        let locked = isClosed || kickoffPassed(game)
        let reveal = myPick(slot) != nil || locked
        return VStack(alignment: .leading, spacing: 4) {
            if let kickoff = game.kickoff {
                Text(Date(timeIntervalSince1970: kickoff).formatted(.dateTime.weekday().month().day().hour().minute()))
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
            HStack(spacing: 6) {
                teamButton(slot: slot, side: 0, abbr: game.away, name: game.awayName,
                           count: pickCount(slot: slot, side: 0), reveal: reveal, locked: locked)
                Text("@")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                teamButton(slot: slot, side: 1, abbr: game.home, name: game.homeName,
                           count: pickCount(slot: slot, side: 1), reveal: reveal, locked: locked)
            }
        }
        .padding(FFSpace.s)
        .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func teamButton(slot: Int, side: Int, abbr: String, name: String?,
                            count: Int, reveal: Bool, locked: Bool) -> some View {
        let isMine = myPick(slot) == side
        return Button {
            onRespond(slot, isMine ? nil : side)
        } label: {
            VStack(spacing: 2) {
                Text(abbr)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                if let name, !name.isEmpty {
                    Text(name)
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                        .lineLimit(1)
                }
                if reveal {
                    Text("\(count)")
                        .font(.ffCaption.bold())
                        .foregroundStyle(isMine ? FFColor.accent : FFColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, FFSpace.s)
            .background(isMine ? FFColor.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: FFRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .strokeBorder(isMine ? FFColor.accent.opacity(0.6) : FFColor.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    private var pickemFooter: some View {
        let answered = Set(responses.filter { $0.userID == myUserID }.map(\.slot)).count
        return Text("\(answered)/\(games.count) picked")
            .font(.ffMicro)
            .foregroundStyle(FFColor.textTertiary)
    }

    // MARK: - Trade block

    private var tradeBlockCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            if let teamName = payload.teamName, !teamName.isEmpty {
                Text(teamName)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
            }
            if let players = payload.players, !players.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.xs) {
                    Text("Offering").ffEyebrow()
                    FlowChips(items: players, ids: payload.playerIDs, tint: FFColor.accent)
                }
            }
            if let seeking = payload.seeking, !seeking.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.xs) {
                    Text("Looking for").ffEyebrow()
                    FlowChips(items: seeking, ids: payload.seekingIDs, tint: FFColor.positive)
                }
            }
            if let note = payload.note, !note.isEmpty {
                Text(note)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// Simple wrapping chip layout for trade-block player names. Uses SwiftUI's
// native Layout so chips flow onto multiple lines within the bubble width.
private struct FlowChips: View {
    let items: [String]
    // Player IDs parallel to `items`. When present, each chip taps through to
    // the player profile; a nil/short list leaves chips inert (older messages).
    var ids: [String]? = nil
    var tint: Color = FFColor.textPrimary

    var body: some View {
        FlowLayout(spacing: FFSpace.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text(item)
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.textPrimary)
                    .padding(.horizontal, FFSpace.s)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
                    .playerLink(idAt(index))
            }
        }
    }

    private func idAt(_ index: Int) -> String? {
        guard let ids, index < ids.count else { return nil }
        return ids[index]
    }
}

// Minimal flow layout: lays subviews left to right, wrapping to a new line
// when the next subview would overflow the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        var rowHeights: [CGFloat] = [0]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                rows.append([])
                rowHeights.append(0)
                x = 0
            }
            rows[rows.count - 1].append(size)
            rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            x += size.width + spacing
        }
        let totalHeight = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width: CGFloat
        if let proposedWidth = proposal.width {
            width = proposedWidth
        } else {
            var widest: CGFloat = 0
            for row in rows {
                var rowWidth: CGFloat = 0
                for size in row {
                    rowWidth += size.width
                }
                rowWidth += spacing * CGFloat(max(0, row.count - 1))
                widest = max(widest, rowWidth)
            }
            width = widest
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
