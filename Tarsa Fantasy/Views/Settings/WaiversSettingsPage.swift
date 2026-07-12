import SwiftUI

// Waiver mode (priority / FAAB), processing schedule, approval, and the
// drag-to-reorder priority list.
struct WaiversSettingsPage: View {
    let league: League
    @Binding var waiverSettings: WaiverSettings
    @Binding var priority: [String]

    var body: some View {
        SettingsPageScaffold(title: "Waivers") {
            Section {
                Picker("Claim resolution", selection: $waiverSettings.mode) {
                    ForEach(WaiverMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                if waiverSettings.mode == .faab {
                    Stepper(value: $waiverSettings.faabBudget, in: 10...1000, step: 10) {
                        HStack {
                            Text("FAAB budget").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                            Spacer()
                            Text("$\(waiverSettings.faabBudget)")
                                .font(.ffStatSmall)
                                .foregroundStyle(FFColor.accent)
                        }
                    }
                }
                Toggle("Commissioner approval", isOn: $waiverSettings.commissionerApproval)
                    .tint(FFColor.accent)
                Picker("Process day", selection: $waiverSettings.processDay) {
                    ForEach(0..<7, id: \.self) { d in
                        Text(WaiverSettings(processDay: d, processHour: 0, periodHours: 0,
                                            commissionerApproval: false).processDayLabel).tag(d)
                    }
                }
                Stepper(value: $waiverSettings.processHour, in: 0...23) {
                    HStack {
                        Text("Process hour (UTC)").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text(String(format: "%02d:00", waiverSettings.processHour))
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
                Stepper(value: $waiverSettings.periodHours, in: 1...168) {
                    HStack {
                        Text("Waiver period").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text("\(waiverSettings.periodHours)h")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
                ForEach(Array(priority.enumerated()), id: \.element) { idx, teamID in
                    HStack {
                        Text("#\(idx + 1)")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                            .frame(width: 32, alignment: .leading)
                        Text(teamName(teamID))
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
                .onMove { from, to in priority.move(fromOffsets: from, toOffset: to) }
            } header: {
                Text("Waivers").ffEyebrow()
            } footer: {
                Text(waiverSettings.mode == .faab
                    ? "FAAB: every claim carries a blind bid from each team's season budget; the highest bid wins (ties go to the better waiver position). When approval is on, every add/drop and waiver claim by another manager waits for you in Activity."
                    : "When approval is on, every add/drop and waiver claim by another manager waits for you in Activity. Priority #1 wins contested claims first; winners roll to the back automatically.")
                    .foregroundStyle(FFColor.textTertiary)
            }
            .listRowBackground(FFColor.surface)
        }
    }

    private func teamName(_ teamID: String) -> String {
        league.teams.first(where: { $0.id == teamID })?.name ?? "Unknown team"
    }
}
