import SwiftUI

// Shared small UI components.

struct PlayerAvatar: View {
    let url: String
    let fallback: String   // initials / position abbreviation

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            default:
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.2))
                    Text(fallback)
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }
}

struct PointsBadge: View {
    let points: Double
    let subtitle: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(String(format: "%.1f", points))
                .font(.system(.headline, design: .rounded)).monospacedDigit()
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct PositionPill: View {
    let position: String

    var body: some View {
        Text(position.isEmpty ? "—" : position)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch position.uppercased() {
        case "QB": return .blue
        case "RB": return .green
        case "WR": return .orange
        case "TE": return .purple
        case "K":  return .pink
        default:   return .gray
        }
    }
}

struct ChipRow<Item: Hashable & Identifiable, Label: View>: View {
    let items: [Item]
    @Binding var selection: Item
    @ViewBuilder var label: (Item) -> Label

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button {
                        selection = item
                    } label: {
                        label(item)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(
                                selection == item
                                    ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(Color.secondary.opacity(0.15)),
                                in: Capsule()
                            )
                            .foregroundStyle(selection == item ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

struct LoadingOverlay: View {
    let isVisible: Bool
    var body: some View {
        if isVisible {
            ZStack {
                Color.black.opacity(0.001) // capture taps without blocking visually much
                ProgressView()
                    .controlSize(.large)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .allowsHitTesting(true)
        }
    }
}

extension Double {
    var fpString: String { String(format: "%.1f", self) }
    var statString: String {
        self == 0 ? "0" : (self.truncatingRemainder(dividingBy: 1) == 0
                           ? String(Int(self))
                           : String(format: "%.1f", self))
    }
}

extension String {
    var initialsFromName: String {
        let parts = self.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first.map { String($0) } }
        return letters.joined().uppercased()
    }
}
