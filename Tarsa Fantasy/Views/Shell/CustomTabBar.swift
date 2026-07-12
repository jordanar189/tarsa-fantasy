import SwiftUI

// Custom bottom navigation bar styled to match the app: brand-gradient active
// tab, surface fill, hairline top border. Fills the full width and extends its
// background under the home indicator. A tab with a positive count in `badges`
// gets a small count pill on its icon (capped at "9+").
struct CustomTabBar: View {
    @Binding var selection: AppTab
    var badges: [AppTab: Int] = [:]

    static let height: CGFloat = 56

    private static let items: [(tab: AppTab, label: String, icon: String)] = [
        (.team,    "Team",    "person.crop.rectangle.stack.fill"),
        (.matchup, "Matchup", "sportscourt.fill"),
        (.league,  "League",  "trophy.fill"),
        (.moves,   "Moves",   "arrow.left.arrow.right"),
        (.players, "Players", "football.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items, id: \.tab) { item in
                let selected = selection == item.tab
                let badgeCount = badges[item.tab] ?? 0
                Button {
                    if selection != item.tab {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                            selection = item.tab
                        }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 20, weight: .semibold))
                            // The active icon pops with a spring — the one
                            // "celebration" the bar allows itself.
                            .scaleEffect(selected ? 1.12 : 1.0)
                            .animation(.spring(response: 0.30, dampingFraction: 0.70), value: selected)
                            // Outside the scale effect so the count pill holds
                            // still while the active icon pops.
                            .overlay(alignment: .topTrailing) {
                                if badgeCount > 0 { badgePill(badgeCount) }
                            }
                        Text(item.label)
                            .font(.system(size: 10, weight: selected ? .bold : .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(
                        selected
                            ? AnyShapeStyle(FFGradient.brand)
                            : AnyShapeStyle(FFColor.textSecondary)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityValue(badgeCount > 0 ? "\(badgeCount) pending" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            FFColor.surface
                .overlay(alignment: .top) {
                    Rectangle().fill(FFColor.border).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func badgePill(_ count: Int) -> some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.ffMicro.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16)
            .frame(height: 16)
            .background(FFColor.live, in: Capsule())
            .offset(x: 10, y: -6)
    }
}
