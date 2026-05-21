import SwiftUI

// Admin-only debug surface for the player projection model. Tune the config,
// run a backtest over a completed season, and read accuracy per position
// against a naive season-average baseline. The whole point is measurability:
// if the model's MAE doesn't beat NAIVE, the signal isn't earning its place.
struct ProjectionBacktestView: View {
    @Environment(AppState.self) private var app

    @State private var season: Int = 0
    @State private var scoring: Scoring = .ppr
    @State private var startWeek: Int = 4
    @State private var config: ProjectionConfig = .default
    @State private var report: BacktestReport? = nil
    @State private var isRunning: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: FFSpace.l) {
                settingsCard
                signalsCard
                runButton
                if let report {
                    resultsCard(report)
                } else if !isRunning {
                    Text("Run a backtest to measure projection accuracy.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, FFSpace.l)
                }
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.top, FFSpace.s)
            .padding(.bottom, 40)
        }
        .ffScreen()
        .navigationTitle("Projection backtest")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .onAppear {
            // Picker selection must match an existing tag, so clamp to a season
            // that's actually in the list.
            if !app.seasons.contains(season) {
                season = app.seasons.contains(app.selectedSeason)
                    ? app.selectedSeason
                    : (app.seasons.first ?? 0)
            }
        }
    }

    // MARK: - Settings

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            Text("Setup").ffEyebrow()

            HStack {
                Text("Season").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Picker("Season", selection: $season) {
                    ForEach(app.seasons, id: \.self) { Text(String($0)).tag($0) }
                }
                .tint(FFColor.accent)
            }

            HStack {
                Text("Scoring").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Picker("Scoring", selection: $scoring) {
                    ForEach(Scoring.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            Stepper(value: $startWeek, in: 1...12) {
                HStack {
                    Text("Start week").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    Text("W\(startWeek)").font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    // MARK: - Signals / config

    private var signalsCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            Text("Model").ffEyebrow()

            Toggle("Matchup (DvP)", isOn: $config.enableMatchup)
            Toggle("Game script (Vegas)", isOn: $config.enableScript)
            Toggle("Availability (injuries)", isOn: $config.enableAvailability)

            slider(title: "Recency decay", value: $config.recencyDecay,
                   range: 0.70...1.0, format: "%.2f")
            slider(title: "Shrinkage games", value: $config.shrinkageGames,
                   range: 0...6, format: "%.1f")
            slider(title: "Matchup range", value: $config.matchupRange,
                   range: 0...0.3, format: "%.2f")
            slider(title: "Script strength", value: $config.scriptStrength,
                   range: 0...1.0, format: "%.2f")

            Button("Reset to defaults") { config = .default }
                .font(.ffCaption)
                .foregroundStyle(FFColor.accent)
        }
        .tint(FFColor.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private func slider(title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
            }
            Slider(value: value, in: range)
        }
    }

    private var runButton: some View {
        Button {
            Task { await run() }
        } label: {
            if isRunning {
                HStack(spacing: FFSpace.s) {
                    ProgressView().tint(.white)
                    Text("Running…")
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Run backtest").frame(maxWidth: .infinity)
            }
        }
        .ffPrimaryButton(disabled: isRunning || season == 0)
        .disabled(isRunning || season == 0)
    }

    // MARK: - Results

    private func resultsCard(_ report: BacktestReport) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack {
                Text("Accuracy").ffEyebrow()
                Spacer()
                if let first = report.weeksTested.first, let last = report.weeksTested.last {
                    Text("W\(first)–W\(last) · \(report.overall.n) samples")
                        .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    headerRow
                    Rectangle().fill(FFColor.border).frame(height: 1)
                    row(report.overall, emphasized: true)
                    ForEach(report.byPosition) { row($0, emphasized: false) }
                }
            }

            Text("MAE = mean abs error. NAIVE = same for a season-average baseline. Δ>0 (green) means the model beats naive. ρ = within-week rank correlation. BIAS>0 over-projects.")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            cell("POS", width: 44, align: .leading, eyebrow: true)
            cell("N", width: 52, eyebrow: true)
            cell("MAE", width: 60, eyebrow: true)
            cell("NAIVE", width: 60, eyebrow: true)
            cell("Δ", width: 56, eyebrow: true)
            cell("BIAS", width: 60, eyebrow: true)
            cell("RMSE", width: 60, eyebrow: true)
            cell("ρ", width: 52, eyebrow: true)
        }
        .padding(.vertical, FFSpace.xs)
    }

    private func row(_ a: PositionAccuracy, emphasized: Bool) -> some View {
        HStack(spacing: 0) {
            cell(a.position, width: 44, align: .leading,
                 color: emphasized ? FFColor.accent : FFColor.textPrimary)
            cell("\(a.n)", width: 52)
            cell(String(format: "%.2f", a.mae), width: 60)
            cell(String(format: "%.2f", a.naiveMAE), width: 60, color: FFColor.textSecondary)
            cell(String(format: "%+.2f", a.improvement), width: 56,
                 color: a.improvement >= 0 ? FFColor.positive : FFColor.negative)
            cell(String(format: "%+.1f", a.bias), width: 60, color: FFColor.textSecondary)
            cell(String(format: "%.2f", a.rmse), width: 60, color: FFColor.textSecondary)
            cell(String(format: "%.2f", a.rankCorrelation), width: 52)
        }
        .padding(.vertical, FFSpace.s)
        .background(emphasized ? FFColor.accentSoft : Color.clear)
    }

    private func cell(_ text: String, width: CGFloat,
                      align: Alignment = .trailing, eyebrow: Bool = false,
                      color: Color = FFColor.textPrimary) -> some View {
        Group {
            if eyebrow {
                Text(text).ffEyebrow(color: FFColor.textTertiary)
            } else {
                Text(text).font(.ffStatSmall).foregroundStyle(color)
            }
        }
        .frame(width: width, alignment: align)
    }

    // MARK: - Run

    private func run() async {
        guard season != 0 else { return }
        isRunning = true
        defer { isRunning = false }
        report = await app.runBacktest(
            season: season, scoring: scoring, config: config, startWeek: startWeek
        )
    }
}

#Preview {
    NavigationStack { ProjectionBacktestView() }
        .environment(AppState.preview)
}
