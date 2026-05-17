import SwiftUI
import Charts

// Bar chart of weekly fantasy points with a horizontal reference line at
// the player's season average. Used in PlayerDetailView Overview to
// visualize boom-or-bust vs. high-floor profiles.
struct PositionDistributionChart: View {
    let games: [Game]
    let scoring: Scoring

    private struct Bar: Identifiable {
        let id: Int
        let week: Int
        let points: Double
    }

    private var bars: [Bar] {
        games.sorted { $0.week < $1.week }
             .map { Bar(id: $0.week, week: $0.week, points: $0.points(scoring: scoring)) }
    }

    private var avg: Double {
        guard !bars.isEmpty else { return 0 }
        return bars.reduce(0) { $0 + $1.points } / Double(bars.count)
    }

    var body: some View {
        if bars.isEmpty {
            EmptyView()
        } else {
            Chart {
                ForEach(bars) { b in
                    BarMark(
                        x: .value("Week", b.week),
                        y: .value("Points", b.points)
                    )
                    .foregroundStyle(b.points >= avg ? FFColor.accent : FFColor.warning)
                    .cornerRadius(2)
                }
                RuleMark(y: .value("Avg", avg))
                    .foregroundStyle(FFColor.textTertiary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXAxis {
                AxisMarks(values: bars.map(\.week)) { value in
                    AxisValueLabel {
                        if let w = value.as(Int.self) {
                            Text("\(w)").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(FFColor.border.opacity(0.3))
                    AxisValueLabel().font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                }
            }
            .frame(height: 140)
        }
    }
}
