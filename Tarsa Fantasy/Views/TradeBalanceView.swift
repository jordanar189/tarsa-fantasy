import SwiftUI

// Trade fairness gauge. Given each side's "receives" list and a precomputed
// value map (Fantasy.tradeValues), it sums the value each side gets and renders
// a balance bar, a plain-language verdict, and a per-player breakdown. Used live
// while composing (ProposeTradeView) and when reviewing a proposal
// (TradeDetailView). Value is on a 0–100 VOR scale; totals are comparative.
struct TradeBalanceView: View {
    let players: [String: Player]
    let values: [String: Double]
    let leftName: String
    let leftReceives: [String]
    let rightName: String
    let rightReceives: [String]
    var showBreakdown: Bool = true

    private func total(_ ids: [String]) -> Double {
        Fantasy.round2(ids.reduce(0) { $0 + (values[$1] ?? 0) })
    }
    private var leftTotal: Double { total(leftReceives) }
    private var rightTotal: Double { total(rightReceives) }
    private var grand: Double { leftTotal + rightTotal }
    private var leftFraction: Double { grand > 0 ? leftTotal / grand : 0.5 }

    // Verdict text + tint. Even within 8%; otherwise names the favored side and
    // grades the tilt. Closer to even reads as fairer (warning vs negative).
    private var verdict: (text: String, color: Color) {
        guard grand > 0 else { return ("Add players to both sides", FFColor.textTertiary) }
        let diff = abs(leftTotal - rightTotal)
        let pct = diff / max(leftTotal, rightTotal)
        if pct < 0.08 { return ("Even trade", FFColor.positive) }
        let favored = leftTotal > rightTotal ? leftName : rightName
        let mag = pct < 0.20 ? "Slightly favors" : (pct < 0.40 ? "Favors" : "Heavily favors")
        return ("\(mag) \(favored)", pct < 0.20 ? FFColor.warning : FFColor.negative)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack {
                Text("TRADE CALCULATOR").ffEyebrow()
                Spacer()
                Text(verdict.text)
                    .font(.ffCaption.bold())
                    .foregroundStyle(verdict.color)
            }
            HStack(alignment: .top, spacing: FFSpace.m) {
                sideTotal(name: leftName, value: leftTotal, align: .leading)
                sideTotal(name: rightName, value: rightTotal, align: .trailing)
            }
            balanceBar
            if showBreakdown && grand > 0 {
                HStack(alignment: .top, spacing: FFSpace.l) {
                    breakdown(ids: leftReceives, align: .leading)
                    breakdown(ids: rightReceives, align: .trailing)
                }
            }
            Text("Value = projected points above a replaceable starter at the position.")
                .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }

    private func sideTotal(name: String, value: Double, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(name.uppercased()).ffEyebrow(color: FFColor.textTertiary).lineLimit(1)
            Text(value.fpString).font(.ffStatLarge).foregroundStyle(FFColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    private var balanceBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(FFColor.accent.opacity(0.22))
                Capsule().fill(FFColor.accent)
                    .frame(width: max(0, min(geo.size.width, geo.size.width * leftFraction)))
                Rectangle().fill(FFColor.bg)
                    .frame(width: 2, height: 16)
                    .position(x: geo.size.width / 2, y: 6)
            }
        }
        .frame(height: 12)
    }

    @ViewBuilder
    private func breakdown(ids: [String], align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 4) {
            ForEach(ids, id: \.self) { id in
                let name = players[id]?.name ?? id
                let v = (values[id] ?? 0).fpString
                if align == .leading {
                    HStack(spacing: 6) {
                        Text(v).font(.ffMicro.bold()).foregroundStyle(FFColor.accent)
                            .frame(width: 34, alignment: .leading)
                        Text(name).font(.ffMicro).foregroundStyle(FFColor.textSecondary).lineLimit(1)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(name).font(.ffMicro).foregroundStyle(FFColor.textSecondary).lineLimit(1)
                        Text(v).font(.ffMicro.bold()).foregroundStyle(FFColor.accent)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }
}
