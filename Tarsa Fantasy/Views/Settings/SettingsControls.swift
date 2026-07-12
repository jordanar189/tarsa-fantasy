import SwiftUI

// Shared stepper rows for the settings pages — the same two shapes every
// page uses, extracted so the split pages don't each carry a private copy.

struct RosterStepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                Text(label).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text("\(value)")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
            }
        }
        .tint(FFColor.accent)
    }
}

struct ScoringStepperRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(label).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Text(value.statString)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
            }
        }
        .tint(FFColor.accent)
    }
}

// The push-destination wrapper every settings page shares: app background,
// hidden Form chrome, inline title. Keeps page files down to their sections.
struct SettingsPageScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            Form { content() }
                .environment(\.editMode, .constant(.active))
                .scrollContentBackground(.hidden)
                .background(FFColor.bg)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
    }
}
