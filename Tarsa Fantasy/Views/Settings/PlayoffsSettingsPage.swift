import SwiftUI

// Playoff field, tiebreaker, bracket shape, and schedule window.
struct PlayoffsSettingsPage: View {
    let league: League
    @Binding var playoffTeams: Int
    @Binding var playoffReseed: Bool
    @Binding var tiebreaker: TiebreakerMode
    @Binding var playoffStartWeek: Int
    @Binding var weeksPerRound: Int

    var body: some View {
        SettingsPageScaffold(title: "Playoffs") {
            Section {
                Stepper(value: $playoffTeams, in: 0...league.teams.count) {
                    HStack {
                        Text("Playoff teams").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text(playoffTeams == 0 ? "Off" : "\(playoffTeams)")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
                .tint(FFColor.accent)
                // Tiebreaker among equal-win% teams; drives standings + seeding.
                Picker(selection: $tiebreaker) {
                    ForEach(TiebreakerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Text("Tiebreaker").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                }
                .pickerStyle(.menu)
                .tint(FFColor.accent)
                if playoffTeams >= 2 {
                    Toggle("Re-seed each round", isOn: $playoffReseed)
                        .tint(FFColor.accent)
                    Stepper(value: $playoffStartWeek, in: playoffStartRange) {
                        HStack {
                            Text("Start week").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                            Spacer()
                            Text("Week \(playoffStartWeek)").font(.ffStatSmall).foregroundStyle(FFColor.accent)
                        }
                    }
                    .tint(FFColor.accent)
                    Picker(selection: $weeksPerRound) {
                        Text("1 week").tag(1)
                        Text("2 weeks").tag(2)
                    } label: {
                        Text("Weeks per round").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                    }
                    .pickerStyle(.menu)
                    .tint(FFColor.accent)
                    HStack {
                        Text("Postseason").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                        Spacer()
                        Text(playoffSummary)
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            } header: {
                Text("Playoffs").ffEyebrow()
            } footer: {
                Text(playoffsFooter)
                    .foregroundStyle(FFColor.textTertiary)
            }
            .listRowBackground(FFColor.surface)
            // Keep the start week valid as the field size / round length change the
            // latest week the bracket can still finish by Week 18.
            .onAppear { clampPlayoffStart() }
            .onChange(of: weeksPerRound) { _, _ in clampPlayoffStart() }
            .onChange(of: playoffTeams) { _, _ in clampPlayoffStart() }
        }
    }

    // Rounds needed for the current field, and the total weeks they span.
    private var playoffSpan: Int {
        guard playoffTeams >= 2 else { return 0 }
        let rounds = max(1, Int(ceil(log2(Double(playoffTeams)))))
        return rounds * max(1, weeksPerRound)
    }
    // Latest start so the championship still ends by Week 18; floor keeps ≥6
    // regular-season weeks when the span allows.
    private var maxPlayoffStartWeek: Int { max(2, League.maxSeasonWeek - playoffSpan + 1) }
    private var minPlayoffStartWeek: Int { min(7, maxPlayoffStartWeek) }
    private var playoffStartRange: ClosedRange<Int> { minPlayoffStartWeek...maxPlayoffStartWeek }
    private var playoffEndWeek: Int { playoffStartWeek + playoffSpan - 1 }

    private func clampPlayoffStart() {
        playoffStartWeek = min(max(playoffStartWeek, minPlayoffStartWeek), maxPlayoffStartWeek)
    }

    private var playoffSummary: String {
        guard playoffTeams >= 2 else { return "Off" }
        return "Weeks \(playoffStartWeek)–\(playoffEndWeek)"
    }

    private var playoffsFooter: String {
        guard playoffTeams >= 2 else {
            return "No postseason — final standings decide it."
        }
        return "Regular season runs Weeks 1–\(playoffStartWeek - 1); playoffs Weeks "
            + "\(playoffStartWeek)–\(playoffEndWeek) (championship Week \(playoffEndWeek)). "
            + "Latest start that finishes by Week \(League.maxSeasonWeek) is Week \(maxPlayoffStartWeek). "
            + "Changing the start week reshuffles the remaining schedule, so set it before games are played."
    }
}
