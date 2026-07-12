import SwiftUI

// Roster slots + keepers + taxi squad. Pushed from the settings root; every
// edit flows straight back into the root's state through bindings and is
// committed by the root's Save.
struct RosterSettingsPage: View {
    let league: League
    @Binding var rosterConfig: RosterConfig
    @Binding var keeperCount: Int
    @Binding var keeperRoundCost: Bool
    @Binding var hasKeeperDeadline: Bool
    @Binding var keeperDeadline: Date?
    @Binding var taxiEnabled: Bool

    var body: some View {
        SettingsPageScaffold(title: "Roster") {
            rosterSection
            taxiSection
        }
    }

    private var rosterSection: some View {
        Section {
            RosterStepperRow(label: "QB",    value: $rosterConfig.qb,    range: 0...4)
            RosterStepperRow(label: "RB",    value: $rosterConfig.rb,    range: 0...6)
            RosterStepperRow(label: "WR",    value: $rosterConfig.wr,    range: 0...6)
            RosterStepperRow(label: "TE",    value: $rosterConfig.te,    range: 0...4)
            RosterStepperRow(label: "FLEX",  value: $rosterConfig.flex,  range: 0...4)
            RosterStepperRow(label: "SFLX",  value: $rosterConfig.superflex, range: 0...2)
            RosterStepperRow(label: "W/R",   value: $rosterConfig.wrFlex,    range: 0...3)
            RosterStepperRow(label: "W/T",   value: $rosterConfig.recFlex,   range: 0...3)
            RosterStepperRow(label: "K",     value: $rosterConfig.k,     range: 0...2)
            RosterStepperRow(label: "DEF",   value: $rosterConfig.def,   range: 0...2)
            RosterStepperRow(label: "DL",    value: $rosterConfig.dl,    range: 0...4)
            RosterStepperRow(label: "LB",    value: $rosterConfig.lb,    range: 0...4)
            RosterStepperRow(label: "DB",    value: $rosterConfig.db,    range: 0...4)
            RosterStepperRow(label: "IDP",   value: $rosterConfig.idpFlex, range: 0...4)
            RosterStepperRow(label: "Bench", value: $rosterConfig.bench, range: 0...12)
            RosterStepperRow(label: "IR",    value: $rosterConfig.ir,    range: 0...6)
            // Keeper-lite: how many players each team carries through the
            // draft. Owners pick theirs in the draft room pre-draft.
            RosterStepperRow(label: "Keepers", value: $keeperCount,
                             range: 0...max(0, rosterConfig.totalSize - 1))
            if keeperCount > 0 {
                Toggle("Keepers cost draft rounds", isOn: $keeperRoundCost)
                    .tint(FFColor.accent)
                Toggle("Keeper deadline", isOn: $hasKeeperDeadline)
                    .tint(FFColor.accent)
                    .onChange(of: hasKeeperDeadline) { _, on in
                        if on {
                            if keeperDeadline == nil {
                                // Default: a week from today, evening.
                                keeperDeadline = Calendar.current.date(
                                    byAdding: .day, value: 7, to: Date()
                                )
                            }
                        } else {
                            keeperDeadline = nil
                        }
                    }
                if hasKeeperDeadline {
                    DatePicker(
                        "Deadline",
                        selection: Binding(
                            get: { keeperDeadline ?? Date() },
                            set: { keeperDeadline = $0 }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .tint(FFColor.accent)
                }
            }
            HStack {
                Text("Total").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text("\(rosterConfig.starterCount) starters · \(rosterConfig.totalSize) max" +
                     (rosterConfig.ir > 0 ? " · \(rosterConfig.ir) IR" : "") +
                     (rosterConfig.taxi > 0 ? " · \(rosterConfig.taxi) taxi" : ""))
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
            }
            if let warning = rosterWarning() {
                Text(warning)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.warning)
            }
        } header: {
            Text("Roster").ffEyebrow()
        } footer: {
            Text(rosterFooter)
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private var rosterFooter: String {
        var text = "Shrinking the roster is allowed even if a team currently has more players — they'll just be unable to add new ones until they drop."
        if keeperCount > 0 {
            text += keeperRoundCost
                ? " Each keeper consumes the team's pick in the round the player cost last season (one round earlier per consecutive keep; undrafted pickups cost the last round)."
                : " Keepers simply carry through: the draft runs \(keeperCount) fewer round\(keeperCount == 1 ? "" : "s")."
            if hasKeeperDeadline {
                text += " Owners can change keepers until the deadline; you can adjust them any time before the draft."
            }
        }
        return text
    }

    private func rosterWarning() -> String? {
        let newTotal = rosterConfig.totalSize
        let over = league.teams.filter { $0.roster.count > newTotal }
        guard !over.isEmpty else { return nil }
        return "\(over.count) team\(over.count == 1 ? "" : "s") currently exceed the new roster size and won't be able to add until they drop."
    }

    // MARK: - Taxi squad

    private var taxiSection: some View {
        Section {
            Toggle("Taxi squad", isOn: $taxiEnabled)
                .tint(FFColor.accent)
                .onChange(of: taxiEnabled) { _, on in
                    if on && rosterConfig.taxi == 0 { rosterConfig.taxi = 2 }
                }
            if taxiEnabled {
                RosterStepperRow(label: "Taxi slots", value: $rosterConfig.taxi, range: 1...10)
                Stepper(value: $rosterConfig.taxiMaxExperience, in: 0...5) {
                    HStack {
                        Text("Max experience").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text(taxiExperienceLabel(rosterConfig.taxiMaxExperience))
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
                .tint(FFColor.accent)
            }
        } header: {
            Text("Taxi squad").ffEyebrow()
        } footer: {
            Text(taxiEnabled
                 ? "Managers can stash up to \(rosterConfig.taxi) \(taxiExperienceLabel(rosterConfig.taxiMaxExperience).lowercased()) off the active roster. Taxi players don't score and don't count against the roster limit."
                 : "Off. Turn on to give managers extra slots for developing inexperienced players.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private func taxiExperienceLabel(_ years: Int) -> String {
        years == 0 ? "Rookies only" : "≤ \(years) year\(years == 1 ? "" : "s") experience"
    }
}
