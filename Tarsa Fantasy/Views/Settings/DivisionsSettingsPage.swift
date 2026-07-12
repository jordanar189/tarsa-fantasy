import SwiftUI

// Division setup: on/off, count, names, and per-team assignment.
struct DivisionsSettingsPage: View {
    let league: League
    @Binding var divisionsEnabled: Bool
    @Binding var divisionNames: [String]
    @Binding var teamDivisions: [String: Int]

    var body: some View {
        SettingsPageScaffold(title: "Divisions") {
            Section {
                Toggle("Divisions", isOn: $divisionsEnabled)
                    .tint(FFColor.accent)
                if divisionsEnabled {
                    Stepper(value: divisionCountBinding, in: 2...max(2, min(4, league.teams.count))) {
                        HStack {
                            Text("Divisions").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                            Spacer()
                            Text("\(divisionNames.count)")
                                .font(.ffStatSmall)
                                .foregroundStyle(FFColor.accent)
                        }
                    }
                    .tint(FFColor.accent)
                    ForEach(divisionNames.indices, id: \.self) { i in
                        HStack {
                            Text("Name \(i + 1)").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                            Spacer()
                            TextField("Division \(i + 1)", text: Binding(
                                get: { divisionNames[i] },
                                set: { divisionNames[i] = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(FFColor.textPrimary)
                        }
                    }
                    ForEach(league.teams) { team in
                        Picker(team.name, selection: divisionBinding(for: team.id)) {
                            ForEach(divisionNames.indices, id: \.self) { i in
                                Text(divisionNames[i]).tag(i)
                            }
                        }
                    }
                }
            } header: {
                Text("Divisions").ffEyebrow()
            } footer: {
                Text("Division winners are seeded ahead of wildcards in the playoff bracket.")
                    .foregroundStyle(FFColor.textTertiary)
            }
            .listRowBackground(FFColor.surface)
        }
    }

    private var divisionCountBinding: Binding<Int> {
        Binding(
            get: { divisionNames.count },
            set: { newCount in
                if newCount > divisionNames.count {
                    for i in divisionNames.count..<newCount { divisionNames.append("Division \(i + 1)") }
                } else if newCount < divisionNames.count {
                    divisionNames = Array(divisionNames.prefix(newCount))
                    // Pull any team assigned to a removed division back to 0.
                    for (tid, d) in teamDivisions where d >= newCount { teamDivisions[tid] = 0 }
                }
            }
        )
    }

    private func divisionBinding(for teamID: String) -> Binding<Int> {
        Binding(
            get: { teamDivisions[teamID] ?? 0 },
            set: { teamDivisions[teamID] = $0 }
        )
    }
}
