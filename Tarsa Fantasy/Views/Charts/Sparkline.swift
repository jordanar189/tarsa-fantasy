import SwiftUI
import Charts

// Tiny inline trend chart used on player rows. Fixed footprint; no axes,
// no legend, no labels. The accent color is faded so the line reads as
// "supporting detail" not "primary content".
struct Sparkline: View {
    let series: [Double]
    var width: CGFloat = 64
    var height: CGFloat = 22

    var body: some View {
        // No data — render a flat 0-line so layout doesn't shift.
        if series.isEmpty {
            Rectangle()
                .fill(FFColor.border)
                .frame(width: width, height: 1)
                .frame(width: width, height: height)
        } else {
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { i, value in
                    LineMark(
                        x: .value("Week", i),
                        y: .value("Points", value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(FFColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    AreaMark(
                        x: .value("Week", i),
                        y: .value("Points", value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [FFColor.accent.opacity(0.25), FFColor.accent.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: chartDomain)
            .frame(width: width, height: height)
        }
    }

    // Pad the Y domain so the line never touches the very top/bottom of the
    // box — gives it room to breathe.
    private var chartDomain: ClosedRange<Double> {
        let minV = series.min() ?? 0
        let maxV = series.max() ?? 1
        if minV == maxV { return (minV - 1)...(maxV + 1) }
        let pad = (maxV - minV) * 0.15
        return (minV - pad)...(maxV + pad)
    }
}
