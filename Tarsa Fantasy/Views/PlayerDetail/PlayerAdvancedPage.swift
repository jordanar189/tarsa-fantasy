import SwiftUI

// Advanced usage: season snap/target/TD-share aggregates plus the weekly
// usage table. Pushed from the player profile hub.
struct PlayerAdvancedPage: View {
    @Environment(AppState.self) private var app
    let player: Player
    let model: PlayerDetailModel

    private var isProjected: Bool { app.isProjectedSeason(app.selectedSeason) }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                advancedSection(for: player)
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
    }

    @ViewBuilder
    private func advancedSection(for p: Player) -> some View {
        if isProjected {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("ADVANCED").ffEyebrow().padding(.leading, FFSpace.s)
                Text("Usage projections (snaps, target share, etc.) aren't available in the preseason. They'll populate once the season kicks off.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.m)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )
            }
        } else {
            advancedSectionReal(for: p)
        }
    }

    private func advancedSectionReal(for p: Player) -> some View {
        let rows = Fantasy.weeklyAdvanced(
            player: p, snapMap: model.snapCounts[p.id],
            teamTargets: model.teamTargets, teamTouchdowns: model.teamTDs
        )
        // Season aggregates for the summary card on top.
        let totalTargets = rows.reduce(0.0) { $0 + $1.targets }
        let totalCarries = rows.reduce(0.0) { $0 + $1.carries }
        let snapAvg = avgNonNil(rows.compactMap { $0.snapPct })
        let tshareAvg = avgNonNil(rows.compactMap { $0.targetShare })
        let tdshareAvg = avgNonNil(rows.compactMap { $0.tdShare })
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            VStack(alignment: .leading, spacing: FFSpace.m) {
                Text("SEASON USAGE").ffEyebrow().padding(.leading, FFSpace.s)
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: FFSpace.m) {
                    statCell("SNAP %",       snapAvg.map { "\(Int($0))%" } ?? "—")
                    statCell("TGT SHARE",    tshareAvg.map { pctString($0) } ?? "—")
                    statCell("TD SHARE",     tdshareAvg.map { pctString($0) } ?? "—")
                    statCell("TARGETS",      totalTargets.statString)
                    statCell("CARRIES",      totalCarries.statString)
                    statCell("YDS / TGT",
                             totalTargets > 0
                             ? Fantasy.round2(rows.reduce(0.0) { $0 + Double($1.targets) * ($1.yardsPerTarget ?? 0) } / totalTargets).fpString
                             : "—")
                }
            }
            .ffCard(padding: FFSpace.l)

            if !rows.isEmpty {
                weeklyAdvancedTable(rows)
            }
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
            Text(label).font(.ffMicro).tracking(0.6).foregroundStyle(FFColor.textTertiary)
        }
    }

    private func weeklyAdvancedTable(_ rows: [Fantasy.WeeklyAdvanced]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("WEEKLY USAGE").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                // Header row
                HStack {
                    Text("WK").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 32, alignment: .leading)
                    Text("SNAP").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 48, alignment: .trailing)
                    Text("TGT").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 40, alignment: .trailing)
                    Text("TGT %").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 56, alignment: .trailing)
                    Text("CAR").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 40, alignment: .trailing)
                    Text("Y/T").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 48, alignment: .trailing)
                    Spacer()
                }
                .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                ForEach(rows, id: \.week) { r in
                    HStack {
                        Text("\(r.week)")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                            .frame(width: 32, alignment: .leading)
                        Text(r.snapPct.map { "\(Int($0))%" } ?? "—")
                            .font(.ffStatSmall).foregroundStyle(snapColor(r.snapPct))
                            .frame(width: 48, alignment: .trailing)
                        Text(r.targets > 0 ? Int(r.targets).description : "—")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(r.targetShare.map { pctString($0) } ?? "—")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                            .frame(width: 56, alignment: .trailing)
                        Text(r.carries > 0 ? Int(r.carries).description : "—")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(r.yardsPerTarget.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                            .frame(width: 48, alignment: .trailing)
                        Spacer()
                    }
                    .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                    .ffHairlineBottom()
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
            Text("Snap %, targets, and shares only. Advanced metrics like ADOT and air-yards land when next-gen-stats ingestion is wired.")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
                .padding(.leading, FFSpace.s)
        }
    }

    private func snapColor(_ pct: Double?) -> Color {
        guard let pct else { return FFColor.textTertiary }
        if pct >= 75 { return FFColor.positive }
        if pct >= 50 { return FFColor.textPrimary }
        if pct >= 25 { return FFColor.warning }
        return FFColor.negative
    }

    private func avgNonNil(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func pctString(_ v: Double) -> String {
        // Target/TD shares are 0..1; render 0..100%.
        let pct = v * 100
        return String(format: "%.0f%%", pct)
    }
}
