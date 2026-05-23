import SwiftUI
import Charts

// Full-width weekly fantasy points chart for the player detail Overview tab.
// Line + points with axis labels; the season average is drawn as a
// horizontal reference line and the season best/worst games get callouts.
struct WeeklyTrendChart: View {
    let games: [Game]
    let scoring: Scoring
    var settings: ScoringSettings? = nil

    private struct Point: Identifiable {
        let id: Int        // week
        let week: Int
        let points: Double
    }

    private var data: [Point] {
        games.sorted { $0.week < $1.week }
             .map { Point(id: $0.week, week: $0.week, points: $0.points(scoring: scoring, settings: settings)) }
    }

    private var seasonAvg: Double {
        guard !data.isEmpty else { return 0 }
        return data.reduce(0) { $0 + $1.points } / Double(data.count)
    }

    var body: some View {
        if data.isEmpty {
            EmptyView()
        } else {
            Chart {
                ForEach(data) { p in
                    LineMark(
                        x: .value("Week", p.week),
                        y: .value("Points", p.points)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(FFColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(
                        x: .value("Week", p.week),
                        y: .value("Points", p.points)
                    )
                    .foregroundStyle(FFColor.accent)
                    .symbolSize(40)
                }
                RuleMark(y: .value("Avg", seasonAvg))
                    .foregroundStyle(FFColor.textTertiary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("AVG \(seasonAvg, format: .number.precision(.fractionLength(1)))")
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
            }
            .chartXAxis {
                AxisMarks(values: data.map(\.week)) { value in
                    AxisGridLine().foregroundStyle(FFColor.border.opacity(0.4))
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
            .frame(height: 180)
        }
    }
}
