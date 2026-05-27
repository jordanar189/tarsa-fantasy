import SwiftUI
import Nuke
import NukeUI

// Shared small UI components used across screens.

// Canonical headshot requests. Every small avatar decodes once, at one pixel
// size, regardless of the point size it's shown at — so a player shown at
// 30/34/36/40pt across screens shares a single decode and cache entry, and the
// prefetcher can warm exactly the image the view later reads back (the cache
// key includes the resize processor, so prefetch and display must build the
// *same* request to hit). Headers above the canonical size (player detail,
// compare) are few on screen and decode at their real size.
//
// The display scale is passed in (from the view's `\.displayScale`) rather than
// read off `UIScreen.main`, so this stays callable off any actor and the
// canonical pixel size adapts to 2x devices instead of baking in 3x.
enum AvatarImage {
    // Covers every list/roster avatar (≤40pt) with headroom.
    static let canonicalMaxPoints: CGFloat = 44

    // Build the resize request in *pixels*. Passing pixels with `.pixels`
    // avoids Nuke's `.points` path, which would multiply by the screen scale a
    // second time and decode ~3× too large on retina devices.
    static func request(_ url: String,
                        displaySize: CGFloat = canonicalMaxPoints,
                        scale: CGFloat) -> ImageRequest? {
        guard !url.isEmpty, let u = URL(string: url) else { return nil }
        // Small avatars all collapse onto the canonical size so they share a
        // cache entry (and match the prefetcher, which has no display size);
        // larger one-off headers decode at their real size.
        let points = displaySize <= canonicalMaxPoints ? canonicalMaxPoints : displaySize
        let pixels = (points * max(scale, 2)).rounded(.up)
        return ImageRequest(
            url: u,
            processors: [ImageProcessors.Resize(
                size: CGSize(width: pixels, height: pixels),
                unit: .pixels,
                contentMode: .aspectFill
            )],
            priority: .normal
        )
    }
}

struct PlayerAvatar: View {
    @Environment(\.displayScale) private var displayScale
    let url: String
    let fallback: String
    var size: CGFloat = 36

    private var request: ImageRequest? {
        AvatarImage.request(url, displaySize: size, scale: displayScale)
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

// MARK: - Team crest

// A fantasy team's crest: the uploaded logo when present, otherwise a designed
// generic default mark tinted by the team's accent color. Used everywhere a
// team is shown compactly (standings, scoreboard, bracket, roster popups) so
// teams without a custom logo still read as branded rather than blank.
struct TeamCrestView: View {
    let logoURL: String?
    let colorHex: String?
    var size: CGFloat = 28

    init(team: FantasyTeam, size: CGFloat = 28) {
        self.logoURL = team.logoURL
        self.colorHex = team.colorHex
        self.size = size
    }

    init(logoURL: String?, colorHex: String?, size: CGFloat = 28) {
        self.logoURL = logoURL
        self.colorHex = colorHex
        self.size = size
    }

    private var accent: Color {
        colorHex.flatMap { Color(hexString: $0) } ?? FFColor.accent
    }

    var body: some View {
        Group {
            if let logoURL, let url = URL(string: logoURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: DefaultTeamCrest(accent: accent, size: size)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(accent.opacity(0.5),
                                               lineWidth: max(1, size * 0.045)))
            } else {
                DefaultTeamCrest(accent: accent, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

// The generic fallback logo for teams that haven't uploaded one. A football
// glyph on an accent-tinted disc with a ring — intentional-looking, and it
// picks up the team's accent color so two unset teams still look distinct.
struct DefaultTeamCrest: View {
    let accent: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: [accent.opacity(0.34), accent.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            Circle().strokeBorder(accent.opacity(0.55), lineWidth: max(1, size * 0.05))
            Image(systemName: "football.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(accent)
                .rotationEffect(.degrees(-35))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Prefetch helpers

// Tiny convenience around Nuke's ImagePrefetcher: feed it the URLs from a
// scrollable list; it warms the decoded-image cache so cells appear instant
// when scrolled into view. Cancelled automatically when the view disappears.
struct AvatarPrefetcher: ViewModifier {
    let urls: [String]
    @Environment(\.displayScale) private var displayScale
    @State private var prefetcher: ImagePrefetcher = ImagePrefetcher(destination: .memoryCache)

    func body(content: Content) -> some View {
        content
            // Prefetch the *same* canonical request PlayerAvatar reads back, so
            // the warm lands in the decoded-image cache (keyed on the resize
            // processor) and not just on disk. Same display scale → same key.
            .onChange(of: urls) { _, new in
                prefetcher.startPrefetching(with: new.compactMap { AvatarImage.request($0, scale: displayScale) })
            }
            .onAppear {
                prefetcher.startPrefetching(with: urls.compactMap { AvatarImage.request($0, scale: displayScale) })
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

// Win-loss(-tie) record with wins in green and losses in red so standings and
// matchup headers read at a glance.
struct ColoredRecord: View {
    let wins: Int
    let losses: Int
    let ties: Int
    var font: Font = .ffCaption

    var body: some View {
        HStack(spacing: 2) {
            Text("\(wins)").foregroundStyle(FFColor.positive)
            Text("–").foregroundStyle(FFColor.textTertiary)
            Text("\(losses)").foregroundStyle(FFColor.negative)
            if ties > 0 {
                Text("–").foregroundStyle(FFColor.textTertiary)
                Text("\(ties)").foregroundStyle(FFColor.textSecondary)
            }
        }
        .font(font)
    }
}

// Position-tinted chip — each position carries its own color (QB red, RB blue,
// WR green, TE orange, K gray, DEF purple) so positions are scannable at a
// glance across dense lists. Empty stays neutral.
struct PositionPill: View {
    let position: String

    private var tint: Color {
        position.isEmpty ? FFColor.textTertiary : FFColor.positionTint(position)
    }

    var body: some View {
        Text(position.isEmpty ? "—" : position)
            .font(.ffMicro)
            .tracking(0.8)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1)
            )
            .foregroundStyle(tint)
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

// Compact owner-assigned value rating chip (HIGH / MED / LOW). Rendered next
// to PositionPill / InjuryBadge on dense player rows. Color-coded so the
// rating reads at a glance: high = positive, medium = warning, low = negative.
struct PlayerValueBadge: View {
    let value: PlayerValue

    private var color: Color {
        switch value {
        case .high:   return FFColor.positive
        case .medium: return FFColor.warning
        case .low:    return FFColor.negative
        }
    }

    var body: some View {
        Text(value.short)
            .font(.ffMicro.bold())
            .tracking(0.8)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color.opacity(0.45), lineWidth: 1)
            )
            .foregroundStyle(color)
            .accessibilityLabel("Value: \(value.label)")
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

// Compact league switcher that lives in the navigation bar's top-leading
// corner (in line with the share/settings buttons) on every league-aware
// screen. Tapping the chip drops an app-styled selection list *downward* as a
// screen overlay (so it isn't clipped by the nav bar). Apply with
// `.leagueSwitcher()` on a view inside a NavigationStack.
extension View {
    func leagueSwitcher() -> some View { modifier(LeagueSwitcherModifier()) }
}

struct LeagueSwitcherModifier: ViewModifier {
    @Environment(AppState.self) private var app
    @State private var expanded = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !app.leagueSummaries.isEmpty {
                        LeagueSwitcherChip(expanded: $expanded)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if expanded {
                    ZStack(alignment: .topLeading) {
                        // Tap-anywhere-to-dismiss scrim (sits below the nav bar
                        // chrome, so the chip stays tappable to toggle closed).
                        Color.black.opacity(0.08)
                            .ignoresSafeArea()
                            .onTapGesture { close() }
                        LeagueSwitcherList(onSelect: { close() })
                            .frame(maxWidth: 300, alignment: .leading)
                            .padding(.leading, FFSpace.m)
                            .padding(.top, FFSpace.xs)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
    }
}

// The compact chip shown in the nav bar. Keeps the bubble styling but sized to
// content so it tucks into the corner.
struct LeagueSwitcherChip: View {
    @Environment(AppState.self) private var app
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FFColor.accent)
                Text(app.selectedLeague?.name ?? "League")
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(FFColor.textTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(FFColor.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(FFColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// The app-styled selection list shown by the switcher dropdown. `onSelect` is
// invoked after a pick so the host can close the overlay.
struct LeagueSwitcherList: View {
    @Environment(AppState.self) private var app
    var onSelect: () -> Void

    var body: some View {
        VStack(spacing: FFSpace.xs) {
            // Scroll the league list past a handful of rows so long lists don't
            // run off-screen. "All leagues" stays pinned below.
            if app.leagueSummaries.count > 6 {
                ScrollView {
                    VStack(spacing: FFSpace.xs) {
                        ForEach(app.leagueSummaries) { lg in leagueRow(lg) }
                    }
                }
                .frame(maxHeight: 300)
            } else {
                ForEach(app.leagueSummaries) { lg in leagueRow(lg) }
            }
            Rectangle().fill(FFColor.border).frame(height: 1)
                .padding(.vertical, 2)
            allLeaguesRow
        }
        .padding(FFSpace.s)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private func leagueRow(_ lg: LeagueSummary) -> some View {
        let selected = lg.id == app.selectedLeagueID
        return Button {
            if !selected { Task { await app.selectLeague(lg.id) } }
            onSelect()
        } label: {
            HStack(spacing: FFSpace.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? FFColor.accent : FFColor.textTertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(lg.name)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: FFSpace.xs) {
                        if lg.isTest {
                            FFPill { Text("SIM").foregroundStyle(FFColor.warning) }
                        }
                        FFPill { Text(String(lg.season)) }
                        FFPill { Text(lg.scoring.label.uppercased()) }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, FFSpace.m)
            .padding(.vertical, FFSpace.s)
            .background(
                selected ? FFColor.accentSoft : FFColor.surfaceElevated,
                in: RoundedRectangle(cornerRadius: FFRadius.s)
            )
        }
        .buttonStyle(.plain)
    }

    private var allLeaguesRow: some View {
        Button {
            onSelect()
            Task { await app.selectLeague(nil) }
        } label: {
            HStack(spacing: FFSpace.s) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15))
                    .foregroundStyle(FFColor.textSecondary)
                Text("All leagues")
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
            }
            .padding(.horizontal, FFSpace.m)
            .padding(.vertical, FFSpace.s)
        }
        .buttonStyle(.plain)
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

// MARK: - Full-screen image viewer

// Identifies a set of images to present full-screen, starting at `index`.
// Use as a `.fullScreenCover(item:)` payload.
struct ImageGallery: Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

// Full-screen, swipeable, pinch-to-zoom image viewer over a black backdrop.
// Paging is enabled when more than one image is supplied.
struct FullScreenImageViewer: View {
    let urls: [String]
    var startIndex: Int = 0

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(urls: [String], startIndex: Int = 0) {
        self.urls = urls
        self.startIndex = startIndex
        _selection = State(initialValue: max(0, min(startIndex, urls.count - 1)))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(urls.enumerated()), id: \.offset) { idx, urlStr in
                    ZoomableImage(urlString: urlStr)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, FFSpace.l)
            .padding(.trailing, FFSpace.l)
        }
    }
}

// A single image with pinch-to-zoom, drag-to-pan (while zoomed), and
// double-tap to toggle zoom. Reset back to fit when zoomed all the way out.
private struct ZoomableImage: View {
    let urlString: String

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var containerSize: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: URL(string: urlString)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .empty:
                    ZStack { Color.clear; ProgressView().tint(.white) }
                default:
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnify)
            .simultaneousGesture(pan)
            .onTapGesture(count: 2) { toggleZoom() }
            .onAppear { containerSize = geo.size }
            .onChange(of: geo.size) { _, newValue in containerSize = newValue }
        }
    }

    // Keep the zoomed image within the viewport: the most it can travel from
    // center is half the overflow (scaledSize - viewSize) on each axis.
    private func clampOffset(_ proposed: CGSize) -> CGSize {
        guard scale > 1, containerSize != .zero else { return .zero }
        let maxX = containerSize.width  * (scale - 1) / 2
        let maxY = containerSize.height * (scale - 1) / 2
        return CGSize(
            width:  min(max(proposed.width,  -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), maxScale)
            }
            .onEnded { _ in
                lastScale = scale
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    offset = clampOffset(offset)
                }
                lastOffset = offset
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clampOffset(CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                ))
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if scale > 1 {
                scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
            } else {
                scale = 2.5; lastScale = 2.5
            }
        }
    }
}
