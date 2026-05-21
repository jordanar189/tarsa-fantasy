import SwiftUI
import Nuke
import NukeUI

// Shared small UI components used across screens.

struct PlayerAvatar: View {
    let url: String
    let fallback: String
    var size: CGFloat = 36

    // Decode at the actual rendered pixel size so a 200px headshot doesn't
    // sit in memory as a 200px UIImage for a 36pt avatar.
    private var request: ImageRequest? {
        guard let u = URL(string: url) else { return nil }
        let scale = max(UIScreen.main.scale, 2)
        let target = CGSize(width: size * scale, height: size * scale)
        return ImageRequest(
            url: u,
            processors: [ImageProcessors.Resize(size: target, contentMode: .aspectFill)],
            priority: .normal
        )
    }

    var body: some View {
        LazyImage(request: request) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(FFColor.surfaceElevated)
                    Text(fallback)
                        .font(.system(size: max(size * 0.32, 10), weight: .semibold))
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 0.5))
    }
}

// MARK: - Prefetch helpers

// Tiny convenience around Nuke's ImagePrefetcher: feed it the URLs from a
// scrollable list; it warms the decoded-image cache so cells appear instant
// when scrolled into view. Cancelled automatically when the view disappears.
struct AvatarPrefetcher: ViewModifier {
    let urls: [String]
    @State private var prefetcher: ImagePrefetcher = ImagePrefetcher(destination: .memoryCache)

    func body(content: Content) -> some View {
        content
            .onChange(of: urls) { _, new in
                let requests = new.compactMap { URL(string: $0).map { ImageRequest(url: $0) } }
                prefetcher.startPrefetching(with: requests)
            }
            .onAppear {
                let requests = urls.compactMap { URL(string: $0).map { ImageRequest(url: $0) } }
                prefetcher.startPrefetching(with: requests)
            }
            .onDisappear { prefetcher.stopPrefetching() }
    }
}

extension View {
    // Attach to a list / scroll view; pass the URLs of avatars that should be
    // ready to display as the user scrolls into them.
    func prefetchAvatars(urls: [String]) -> some View {
        self.modifier(AvatarPrefetcher(urls: urls))
    }
}

// Monochrome — same shape and tone for every position. Position is encoded
// in the letterforms, not the color. Reduces visual noise on dense lists.
struct PositionPill: View {
    let position: String

    var body: some View {
        Text(position.isEmpty ? "—" : position)
            .font(.ffMicro)
            .tracking(0.8)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
            .foregroundStyle(FFColor.textSecondary)
    }
}

// Compact health-status chip. Red for game-locking (Out/IR/PUP/Susp), yellow
// for game-day decisions (Q/D). Pair with PositionPill on dense player rows.
struct InjuryBadge: View {
    let injury: Injury

    private var color: Color {
        switch injury.status.uppercased() {
        case "OUT", "IR", "INJURED RESERVE", "PUP", "SUSPENDED": return FFColor.negative
        case "DOUBTFUL", "QUESTIONABLE":                          return FFColor.warning
        default:                                                  return FFColor.textSecondary
        }
    }

    var body: some View {
        Text(injury.badge)
            .font(.ffMicro.bold())
            .tracking(0.8)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
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
                            .font(.ffMicro)
                            .tracking(0.6)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(
                                selection == item
                                    ? AnyShapeStyle(FFGradient.brand)
                                    : AnyShapeStyle(Color.clear),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    selection == item ? Color.clear : FFColor.border,
                                    lineWidth: 1
                                )
                            )
                            .foregroundStyle(selection == item ? .white : FFColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, FFSpace.l)
        }
    }
}

// Reusable segmented tab switcher used everywhere we have 2-5 equal-width
// sub-tabs. Soft accent pill behind the selected item, dim text on the
// rest, all wrapped in the standard surface card. One place to tweak the
// look means every switcher in the app stays consistent.
struct SegmentedTabPicker<T: Hashable & Identifiable, Label: View>: View {
    let items: [T]
    @Binding var selection: T
    @ViewBuilder var label: (T) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = item }
                } label: {
                    label(item)
                        .font(.ffCaption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(
                            selection == item
                                ? AnyShapeStyle(FFGradient.brand)
                                : AnyShapeStyle(FFColor.textSecondary)
                        )
                        .background(
                            selection == item
                                ? AnyShapeStyle(FFGradient.brandSoft)
                                : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: FFRadius.xs)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }
}

struct LoadingOverlay: View {
    let isVisible: Bool
    var body: some View {
        if isVisible {
            ZStack {
                Color.black.opacity(0.001)
                ProgressView()
                    .controlSize(.large)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .allowsHitTesting(true)
        }
    }
}

// Thin indeterminate progress bar — 2pt tall, accent-colored segment sliding
// left-to-right. Used as a global indicator when the season data is being
// refreshed in the background (we already painted cached data, so this is
// the only signal the user gets that fresher numbers are arriving).
struct TopRefreshIndicator: View {
    var isActive: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let segmentWidth = trackWidth * 0.30
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(FFColor.accent.opacity(0.08))
                Capsule()
                    .fill(FFGradient.brand)
                    .frame(width: segmentWidth, height: 2)
                    // Slide from off-left to off-right and loop.
                    .offset(x: -segmentWidth + (trackWidth + segmentWidth) * phase)
            }
            .frame(height: 2)
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: isActive)
            .onAppear {
                guard isActive else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    phase = 0
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

// Compact matchup-difficulty pill for the player rows and detail header.
// Green = soft defense (high fantasy production allowed at this position),
// Red = stout defense, Yellow = middle of the pack.
struct MatchupPill: View {
    let rating: MatchupRating
    var rank: Int? = nil
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            if !compact {
                Text(rating.label).tracking(0.6)
            }
            if let rank, !compact {
                Text("#\(rank)")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .font(.ffMicro)
        .padding(.horizontal, compact ? 4 : 7).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
        .foregroundStyle(color)
    }

    private var color: Color {
        switch rating {
        case .green:   return FFColor.positive
        case .yellow:  return FFColor.warning
        case .red:     return FFColor.negative
        case .unknown: return FFColor.textTertiary
        }
    }
}

// Small filled badge that marks the league's commissioner. Painted with the
// brand gradient so the commish jumps out on the leagues list and member
// rolls without needing a different shape or layout.
struct CommissionerBadge: View {
    var compact: Bool = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 10, weight: .bold))
            if !compact { Text("COMMISH") }
        }
        .font(.ffMicro)
        .tracking(0.8)
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, 4)
        .background(FFGradient.brand, in: Capsule())
        .foregroundStyle(.white)
    }
}

extension Color {
    // Parses "#RRGGBB" / "RRGGBB" into a Color. Returns nil for malformed
    // input so callers can fall back to a default accent.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red:   Double((v & 0xFF0000) >> 16) / 255,
            green: Double((v & 0x00FF00) >> 8) / 255,
            blue:  Double(v & 0x0000FF) / 255
        )
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
