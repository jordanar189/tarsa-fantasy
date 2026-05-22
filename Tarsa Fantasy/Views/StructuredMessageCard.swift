import SwiftUI

// Renders a structured chat card — poll, pick'em, trivia, or trade block —
// inside the league chat transcript. Vote tallies come from `responses`
// (one row per user); tapping an option calls `onRespond` with its index.
struct StructuredMessageCard: View {
    let message: LeagueMessage
    let responses: [MessageResponse]
    let myUserID: String?
    let onRespond: (Int) -> Void

    private var payload: ChatPayload { message.payload ?? ChatPayload() }
    private var options: [String] { payload.options ?? [] }
    private var total: Int { responses.count }
    private var myChoice: Int? {
        guard let me = myUserID else { return nil }
        return responses.first(where: { $0.userID == me })?.choice
    }

    private func count(for index: Int) -> Int {
        responses.reduce(0) { $0 + ($1.choice == index ? 1 : 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            header
            switch message.kind {
            case .poll, .pickem, .trivia:
                votingCard
            case .tradeblock:
                tradeBlockCard
            case .text:
                EmptyView()
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
        }
        .foregroundStyle(FFColor.accent)
    }

    private var icon: String {
        switch message.kind {
        case .poll:       return "chart.bar.fill"
        case .pickem:     return "football.fill"
        case .trivia:     return "questionmark.circle.fill"
        case .tradeblock: return "arrow.left.arrow.right"
        case .text:       return "bubble.left"
        }
    }

    private var eyebrow: String {
        switch message.kind {
        case .poll:       return "POLL"
        case .pickem:     return "PICK 'EM"
        case .trivia:     return "TRIVIA"
        case .tradeblock: return "ON THE BLOCK"
        case .text:       return ""
        }
    }

    // MARK: - Poll / pick'em / trivia

    private var votingCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            if let question = payload.question, !question.isEmpty {
                Text(question)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, label: option)
                }
            }
            footerLine
        }
    }

    // Trivia hides tallies until the viewer has answered, so it stays a
    // guessing game; polls and pick'em always show results.
    private var resultsVisible: Bool {
        message.kind == .trivia ? (myChoice != nil) : true
    }

    @ViewBuilder
    private func optionRow(index: Int, label: String) -> some View {
        let c = count(for: index)
        let fraction = total > 0 ? Double(c) / Double(total) : 0
        let isMine = myChoice == index
        let isCorrect = message.kind == .trivia && payload.correct == index
        let revealCorrect = message.kind == .trivia && myChoice != nil && isCorrect
        let revealWrongPick = message.kind == .trivia && isMine && payload.correct != index

        Button {
            onRespond(index)
        } label: {
            ZStack(alignment: .leading) {
                // Tally bar.
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: FFRadius.s)
                        .fill(barColor(isMine: isMine, revealCorrect: revealCorrect, revealWrong: revealWrongPick))
                        .frame(width: resultsVisible ? max(0, geo.size.width * fraction) : 0)
                }
                HStack(spacing: FFSpace.s) {
                    Text(label)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: FFSpace.s)
                    if revealCorrect {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(FFColor.positive)
                    } else if revealWrongPick {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(FFColor.negative)
                    } else if isMine {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(FFColor.accent)
                    }
                    if resultsVisible {
                        Text("\(c)")
                            .font(.ffCaption.bold())
                            .foregroundStyle(FFColor.textSecondary)
                            .frame(minWidth: 16, alignment: .trailing)
                    }
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
    }

    private func barColor(isMine: Bool, revealCorrect: Bool, revealWrong: Bool) -> Color {
        if revealCorrect { return FFColor.positive.opacity(0.22) }
        if revealWrong   { return FFColor.negative.opacity(0.18) }
        if isMine        { return FFColor.accentSoft }
        return FFColor.accent.opacity(0.10)
    }

    private var footerLine: some View {
        let votersLabel = total == 1 ? "1 vote" : "\(total) votes"
        return Text(message.kind == .trivia && myChoice == nil ? "Tap to answer" : votersLabel)
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
                FlowChips(items: players)
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

    var body: some View {
        FlowLayout(spacing: FFSpace.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.textPrimary)
                    .padding(.horizontal, FFSpace.s)
                    .padding(.vertical, 4)
                    .background(FFColor.surfaceElevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(FFColor.border, lineWidth: 1))
            }
        }
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
        let width = proposal.width ?? rows.map { row in
            row.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, row.count - 1))
        }.max() ?? 0
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
