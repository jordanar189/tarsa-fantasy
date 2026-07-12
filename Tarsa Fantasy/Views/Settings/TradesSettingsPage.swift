import SwiftUI

// Trade approval mode, deadline, and vote window.
struct TradesSettingsPage: View {
    @Binding var tradeSettings: TradeSettings
    @Binding var hasTradeDeadline: Bool

    var body: some View {
        SettingsPageScaffold(title: "Trades") {
            Section {
                Picker("Approval", selection: $tradeSettings.approval) {
                    ForEach(TradeApprovalMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("Trade deadline", isOn: $hasTradeDeadline)
                    .tint(FFColor.accent)
                    .onChange(of: hasTradeDeadline) { _, on in
                        if on {
                            // Default deadline: ~10 weeks from today.
                            if tradeSettings.deadline == nil {
                                tradeSettings.deadline = Calendar.current.date(
                                    byAdding: .day, value: 70, to: Date()
                                )
                            }
                        } else {
                            tradeSettings.deadline = nil
                        }
                    }
                if hasTradeDeadline {
                    DatePicker(
                        "Deadline date",
                        selection: Binding(
                            get: { tradeSettings.deadline ?? Date() },
                            set: { tradeSettings.deadline = $0 }
                        ),
                        in: Date()...,
                        displayedComponents: [.date]
                    )
                    .tint(FFColor.accent)
                }
                if tradeSettings.approval == .leagueVote {
                    Stepper(value: $tradeSettings.voteHours, in: 1...168) {
                        HStack {
                            Text("Vote window").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                            Spacer()
                            Text("\(tradeSettings.voteHours)h")
                                .font(.ffStatSmall)
                                .foregroundStyle(FFColor.accent)
                        }
                    }
                }
            } header: {
                Text("Trades").ffEyebrow()
            } footer: {
                Text(tradesFooter)
                    .foregroundStyle(FFColor.textTertiary)
            }
            .listRowBackground(FFColor.surface)
        }
    }

    private var tradesFooter: String {
        switch tradeSettings.approval {
        case .none:
            return "Accepted trades execute as soon as all included players are unlocked."
        case .commissioner:
            return "Every accepted trade waits for you to approve in the Trades tab before executing."
        case .leagueVote:
            return "Accepted trades open for league veto for the configured window. Majority of other owners can reverse them."
        }
    }
}
