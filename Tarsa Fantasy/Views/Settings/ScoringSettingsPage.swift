import SwiftUI

// Custom per-stat scoring weights. The preset picker lives on the settings
// root (General); this page holds the toggle + full weight table.
struct ScoringSettingsPage: View {
    let scoring: Scoring
    @Binding var useCustomScoring: Bool
    @Binding var scoringSettings: ScoringSettings

    var body: some View {
        SettingsPageScaffold(title: "Scoring") {
            Section {
                Toggle("Custom scoring", isOn: $useCustomScoring)
                    .tint(FFColor.accent)
                if useCustomScoring {
                    ScoringStepperRow(label: "Pass yds / point", value: $scoringSettings.passingYardsPerPoint, range: 5...50, step: 5)
                    ScoringStepperRow(label: "Pass TD",          value: $scoringSettings.passingTD,            range: 0...10, step: 1)
                    ScoringStepperRow(label: "Interception",     value: $scoringSettings.interception,         range: -5...0, step: 1)
                    ScoringStepperRow(label: "Rush yds / point", value: $scoringSettings.rushingYardsPerPoint, range: 5...20, step: 1)
                    ScoringStepperRow(label: "Rush TD",          value: $scoringSettings.rushingTD,            range: 0...10, step: 1)
                    ScoringStepperRow(label: "Rec yds / point",  value: $scoringSettings.receivingYardsPerPoint, range: 5...20, step: 1)
                    ScoringStepperRow(label: "Rec TD",           value: $scoringSettings.receivingTD,          range: 0...10, step: 1)
                    ScoringStepperRow(label: "Per reception",    value: $scoringSettings.reception,            range: 0...2, step: 0.5)
                    ScoringStepperRow(label: "Fumble lost",      value: $scoringSettings.fumbleLost,           range: -5...0, step: 1)

                    Text("Kicking").ffEyebrow()
                    ScoringStepperRow(label: "FG 0–39",          value: $scoringSettings.fgUnder40,            range: 0...10, step: 1)
                    ScoringStepperRow(label: "FG 40–49",         value: $scoringSettings.fg40to49,            range: 0...10, step: 1)
                    ScoringStepperRow(label: "FG 50+",           value: $scoringSettings.fg50plus,            range: 0...10, step: 1)
                    ScoringStepperRow(label: "Extra point",      value: $scoringSettings.patMade,             range: 0...5, step: 1)
                    ScoringStepperRow(label: "Missed FG",        value: $scoringSettings.fgMissed,            range: -5...0, step: 1)
                    ScoringStepperRow(label: "Missed PAT",       value: $scoringSettings.patMissed,           range: -5...0, step: 1)

                    Text("Defense (DST)").ffEyebrow()
                    ScoringStepperRow(label: "Sack",             value: $scoringSettings.defSack,             range: 0...5, step: 0.5)
                    ScoringStepperRow(label: "Interception",     value: $scoringSettings.defInterception,     range: 0...10, step: 1)
                    ScoringStepperRow(label: "Fumble recovery",  value: $scoringSettings.defFumbleRecovery,   range: 0...10, step: 1)
                    ScoringStepperRow(label: "Defensive TD",     value: $scoringSettings.defTouchdown,        range: 0...10, step: 1)
                    ScoringStepperRow(label: "Safety",           value: $scoringSettings.defSafety,           range: 0...10, step: 1)

                    Text("DST points allowed").ffEyebrow()
                    ScoringStepperRow(label: "Shutout",          value: $scoringSettings.paShutout,           range: 0...15, step: 1)
                    ScoringStepperRow(label: "1–6 allowed",      value: $scoringSettings.paUnder7,            range: 0...12, step: 1)
                    ScoringStepperRow(label: "7–13 allowed",     value: $scoringSettings.paUnder14,           range: 0...10, step: 1)
                    ScoringStepperRow(label: "14–20 allowed",    value: $scoringSettings.paUnder21,           range: -3...6, step: 1)
                    ScoringStepperRow(label: "21–27 allowed",    value: $scoringSettings.paUnder28,           range: -4...4, step: 1)
                    ScoringStepperRow(label: "28–34 allowed",    value: $scoringSettings.paUnder35,           range: -6...2, step: 1)
                    ScoringStepperRow(label: "35+ allowed",      value: $scoringSettings.pa35Plus,            range: -8...0, step: 1)

                    Text("IDP").ffEyebrow()
                    ScoringStepperRow(label: "Solo tackle",      value: $scoringSettings.idpSoloTackle,     range: 0...4, step: 0.25)
                    ScoringStepperRow(label: "Assisted tackle",  value: $scoringSettings.idpAssistTackle,   range: 0...2, step: 0.25)
                    ScoringStepperRow(label: "Tackle for loss",  value: $scoringSettings.idpTackleForLoss,  range: 0...6, step: 0.5)
                    ScoringStepperRow(label: "Sack",             value: $scoringSettings.idpSack,           range: 0...10, step: 0.5)
                    ScoringStepperRow(label: "QB hit",           value: $scoringSettings.idpQbHit,          range: 0...4, step: 0.5)
                    ScoringStepperRow(label: "Interception",     value: $scoringSettings.idpInterception,   range: 0...10, step: 1)
                    ScoringStepperRow(label: "Pass defended",    value: $scoringSettings.idpPassDefended,   range: 0...5, step: 0.5)
                    ScoringStepperRow(label: "Forced fumble",    value: $scoringSettings.idpForcedFumble,   range: 0...10, step: 1)
                    ScoringStepperRow(label: "Fumble recovery",  value: $scoringSettings.idpFumbleRecovery, range: 0...10, step: 1)
                    ScoringStepperRow(label: "Defensive TD",     value: $scoringSettings.idpTouchdown,      range: 0...10, step: 1)
                    ScoringStepperRow(label: "Safety",           value: $scoringSettings.idpSafety,         range: 0...10, step: 1)
                }
            } header: {
                Text("Scoring").ffEyebrow()
            } footer: {
                Text(useCustomScoring
                     ? "Custom weights are applied to every game retroactively, computed from raw stat lines. Any player scores for any action they record."
                     : "Using the \(scoring.label) preset. Turn on custom scoring to set per-stat values.")
                    .foregroundStyle(FFColor.textTertiary)
            }
            .listRowBackground(FFColor.surface)
        }
    }
}
