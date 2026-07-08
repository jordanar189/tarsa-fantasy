import SwiftUI
import UIKit

// Single source of truth for visual design — colors, typography, spacing,
// and reusable view modifiers. Colors resolve dynamically based on the
// current UIUserInterfaceStyle, so the same FFColor.bg renders dark navy
// in dark mode and near-white in light mode. The app-level color scheme
// override (ContentView.preferredColorScheme) drives which side wins.

private func dynamicColor(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? dark : light
    })
}

private func rgb(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1) -> UIColor {
    UIColor(red: r, green: g, blue: b, alpha: alpha)
}

extension AppTheme {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil           // follow device
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum FFColor {
    // Backgrounds
    static let bg              = dynamicColor(
        light: rgb(0.97, 0.97, 0.98),   // #f7f7fa
        dark:  rgb(0.04, 0.05, 0.10)    // #0a0d1a
    )
    static let surface         = dynamicColor(
        light: rgb(1.00, 1.00, 1.00),   // #ffffff
        dark:  rgb(0.07, 0.09, 0.14)    // #131826
    )
    static let surfaceElevated = dynamicColor(
        light: rgb(0.94, 0.95, 0.97),   // #f0f2f7
        dark:  rgb(0.10, 0.12, 0.18)    // #1a1f2e
    )
    static let border          = dynamicColor(
        light: rgb(0.88, 0.90, 0.93),   // #e1e5ed
        dark:  rgb(0.14, 0.17, 0.24)    // #232a3d
    )
    static let borderStrong    = dynamicColor(
        light: rgb(0.74, 0.77, 0.83),   // #bdc4d4
        dark:  rgb(0.20, 0.24, 0.33)    // #333d54
    )

    // Text
    static let textPrimary     = dynamicColor(
        light: rgb(0.07, 0.09, 0.14),   // #131826
        dark:  rgb(0.91, 0.92, 0.95)    // #e8eaf2
    )
    static let textSecondary   = dynamicColor(
        light: rgb(0.36, 0.39, 0.48),   // #5d647a
        dark:  rgb(0.55, 0.57, 0.66)    // #8b91a8
    )
    static let textTertiary    = dynamicColor(
        light: rgb(0.55, 0.58, 0.66)    // #8b95a8
        ,
        dark:  rgb(0.34, 0.36, 0.45)    // #565d72
    )

    // Brand & semantic. Accent stays the same hue across modes but a touch
    // darker in light mode for better contrast on white.
    static let accent          = dynamicColor(
        light: rgb(0.05, 0.55, 0.70),   // #0e8db3
        dark:  rgb(0.27, 0.89, 1.00)    // #46e4ff
    )
    static let accentSoft      = dynamicColor(
        light: rgb(0.05, 0.55, 0.70, alpha: 0.12),
        dark:  rgb(0.27, 0.89, 1.00, alpha: 0.12)
    )
    static let positive        = dynamicColor(
        light: rgb(0.10, 0.62, 0.42),   // #199d6b
        dark:  rgb(0.20, 0.83, 0.60)    // #34d399
    )
    static let negative        = dynamicColor(
        light: rgb(0.84, 0.22, 0.27),   // #d63845
        dark:  rgb(0.97, 0.44, 0.44)    // #f87171
    )
    static let warning         = dynamicColor(
        light: rgb(0.78, 0.55, 0.05),   // #c78d0e
        dark:  rgb(0.98, 0.75, 0.14)    // #fbbf24
    )

    // Position tints — used in surfaces where rapid position scanning helps
    // (draft pick grid, etc.). Layer at opacity 0.18–0.25 for backgrounds,
    // full opacity for accents. Slightly desaturated in light mode so the
    // tinted backgrounds don't overpower the white surface.
    static func positionTint(_ position: String) -> Color {
        switch position.uppercased() {
        case "QB":  return dynamicColor(
            light: rgb(0.80, 0.28, 0.24),
            dark:  rgb(0.94, 0.42, 0.36)
        )
        case "RB":  return dynamicColor(
            light: rgb(0.20, 0.45, 0.85),
            dark:  rgb(0.40, 0.65, 0.98)
        )
        case "WR":  return dynamicColor(
            light: rgb(0.15, 0.65, 0.38),
            dark:  rgb(0.34, 0.82, 0.55)
        )
        case "TE":  return dynamicColor(
            light: rgb(0.82, 0.50, 0.16),
            dark:  rgb(0.96, 0.66, 0.32)
        )
        case "K":   return dynamicColor(
            light: rgb(0.45, 0.50, 0.60),
            dark:  rgb(0.70, 0.72, 0.80)
        )
        case "DEF": return dynamicColor(
            light: rgb(0.45, 0.30, 0.78),
            dark:  rgb(0.66, 0.50, 0.92)
        )
        default:    return textTertiary
        }
    }
}

enum FFSpace {
    static let xs:  CGFloat = 4
    static let s:   CGFloat = 8
    static let m:   CGFloat = 12
    static let l:   CGFloat = 16
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum FFRadius {
    static let xs: CGFloat = 6
    static let s:  CGFloat = 10
    static let m:  CGFloat = 14
    static let l:  CGFloat = 18
}

// MARK: - Typography

extension Font {
    static let ffDisplay  = Font.system(size: 32, weight: .bold,     design: .default)
    static let ffTitle    = Font.system(size: 22, weight: .semibold, design: .default)
    static let ffHeadline = Font.system(size: 17, weight: .semibold, design: .default)
    static let ffBody     = Font.system(size: 15, weight: .regular,  design: .default)
    static let ffCaption  = Font.system(size: 13, weight: .regular,  design: .default)
    static let ffMicro    = Font.system(size: 11, weight: .semibold, design: .default)

    // Monospaced — for stats, scores, codes
    static let ffStatLarge  = Font.system(size: 26, weight: .bold,     design: .monospaced)
    static let ffStatMedium = Font.system(size: 18, weight: .semibold, design: .monospaced)
    static let ffStatSmall  = Font.system(size: 14, weight: .medium,   design: .monospaced)
}

// MARK: - View modifiers

extension View {
    // Card surface with hairline border. Use for grouped content.
    func ffCard(padding: CGFloat = FFSpace.l) -> some View {
        self
            .padding(padding)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }

    // Inset row used inside lists where each row should feel like its own card.
    func ffRow() -> some View {
        self
            .padding(.horizontal, FFSpace.l)
            .padding(.vertical, FFSpace.m)
    }

    // Hairline divider as a 1px line in the border color.
    func ffHairlineBottom() -> some View {
        self.overlay(alignment: .bottom) {
            Rectangle()
                .fill(FFColor.border)
                .frame(height: 0.5)
        }
    }

    // Primary call-to-action button. Full width, brand gradient fill, pill
    // shape. White foreground reads cleanly on the cyan→violet gradient in
    // both modes — don't swap it for FFColor.bg or it'll vanish in light.
    //
    // Implemented as a ButtonStyle so the fill + hit shape are applied to the
    // button's *label* (inside the button), which is the only way the whole
    // pill becomes tappable. Apply directly to a Button.
    func ffPrimaryButton(disabled: Bool = false) -> some View {
        buttonStyle(FFPrimaryButtonStyle(disabled: disabled))
    }

    // Secondary button — outlined, smaller emphasis. Also a ButtonStyle so the
    // empty outlined fill still gets a full-bleed hit target.
    func ffSecondaryButton() -> some View {
        buttonStyle(FFSecondaryButtonStyle())
    }

    // Small uppercased label — section headers, eyebrows, badges.
    func ffEyebrow(color: Color = FFColor.textSecondary) -> some View {
        self
            .font(.ffMicro)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    // Container background — applies the app's base color to a screen.
    func ffScreen() -> some View {
        self.background(FFColor.bg.ignoresSafeArea())
    }

    // Hero card surface — the "scoreboard-grade" container. Reserved for
    // top-of-screen anchors (matchup banner, week totals, player detail
    // header, draft on-the-clock). A subtle brand wash under the regular
    // surface adds depth without noise; the radius is a touch larger than
    // ffCard so the hero reads as a distinct tier. Pass `accentStripe: true`
    // for a thin top edge highlight (e.g. "you're winning"). Do NOT apply
    // this to every card — its punch comes from being used sparingly.
    func ffHeroCard(
        padding: CGFloat = FFSpace.l,
        accentStripe: Bool = false,
        accentTint: Color = FFColor.accent
    ) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: FFRadius.l)
                    .fill(FFColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.l)
                            .fill(FFGradient.brandWash)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.l)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                if accentStripe {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accentTint)
                        .frame(height: 3)
                        .padding(.horizontal, FFSpace.xxxl)
                        .padding(.top, 1)
                }
            }
    }
}

// MARK: - Hero primitives
//
// Small, composable views that reproduce the score-banner recipe across the
// app's hero surfaces. Each one is intentionally minimal — they layer onto
// the existing FFColor / FFSpace / FFRadius primitives, so a hero card is
// always: ffHeroCard { BigStat / WinBar / StateChip / ... }.

// Eyebrow-label + big monospaced value + optional caption. The visual anchor
// of hero cards. Three sizes match the recipe used by the score banner
// (.large for headline scores), totals card (.medium), and dense recap grids
// (.small).
struct BigStat: View {
    enum Size {
        case small, medium, large
        var pointSize: CGFloat {
            switch self {
            case .small:  20
            case .medium: 28
            case .large:  36
            }
        }
    }

    let label: String
    let value: String
    var caption: String? = nil
    var tint: Color = FFColor.textPrimary
    var alignment: HorizontalAlignment = .leading
    var size: Size = .medium

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading:  return .leading
        case .trailing: return .trailing
        default:        return .center
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label.uppercased())
                .font(.ffMicro.bold()).tracking(1.4)
                .foregroundStyle(FFColor.textTertiary)
            Text(value)
                .font(.system(size: size.pointSize, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let caption {
                Text(caption)
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

// Status pill used inside hero surfaces. The pulse dot + tracked eyebrow is
// the same vocabulary as the matchup banner — "live" wherever something is
// happening now, "final" for completed state, "scheduled" for upcoming.
// "locked" warns about an irreversible deadline (e.g. lineup lock); "auto"
// marks an automated agent in control (e.g. auto-pick).
struct StateChip: View {
    enum State {
        case live, final, scheduled, locked, auto

        var color: Color {
            switch self {
            case .live:      return FFColor.negative
            case .final:     return FFColor.textTertiary
            case .scheduled: return FFColor.textTertiary
            case .locked:    return FFColor.warning
            case .auto:      return FFColor.accent
            }
        }
        var showsPulse: Bool { self == .live }
    }

    let state: State
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            if state.showsPulse {
                Circle().fill(state.color)
                    .frame(width: 6, height: 6)
                    .shadow(color: state.color.opacity(0.7), radius: 4)
            }
            Text(label.uppercased())
                .font(.ffMicro.bold()).tracking(1.4)
                .foregroundStyle(state.color)
        }
    }
}

// Two-sided percentage bar used by the score banner. Extracted as a primitive
// so any "me vs other" probability surface (matchup, draft pick odds, trade
// fairness) can drop it in. The fill is the accent and reads left-to-right
// from the viewer's perspective.
struct WinBar: View {
    // 0...1 — fraction of the bar that belongs to "me". 0.5 is even.
    let myPercent: Double
    var middleLabel: String? = "WIN PROBABILITY"

    var body: some View {
        let clamped = max(0, min(1, myPercent))
        let mePct = Int((clamped * 100).rounded())
        let oppPct = 100 - mePct
        VStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(FFColor.accent)
                        .frame(width: max(0, geo.size.width * clamped))
                    Rectangle().fill(FFColor.surfaceElevated)
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack {
                Text("\(mePct)%").font(.ffMicro.bold()).foregroundStyle(FFColor.accent)
                Spacer()
                if let middleLabel {
                    Text(middleLabel.uppercased()).font(.ffMicro).tracking(1.2)
                        .foregroundStyle(FFColor.textTertiary)
                    Spacer()
                }
                Text("\(oppPct)%").font(.ffMicro.bold()).foregroundStyle(FFColor.textSecondary)
            }
        }
    }
}

// MARK: - Button styles

// The styling lives in ButtonStyle.makeBody (applied to configuration.label)
// rather than as a plain view modifier so the full pill — padding, fill, and
// border included — is the tappable region. A bare `.frame(maxWidth:.infinity)`
// modifier on a Button only stretches the frame; the hit target stays the
// label's intrinsic size unless contentShape is set *inside* the button.
struct FFPrimaryButtonStyle: ButtonStyle {
    var disabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ffHeadline)
            .foregroundStyle(disabled ? FFColor.textTertiary : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .fill(disabled
                          ? AnyShapeStyle(FFColor.borderStrong)
                          : AnyShapeStyle(FFGradient.brand))
            )
            .contentShape(Rectangle())
            .shadow(color: disabled ? .clear : FFBrand.violet.opacity(0.30),
                    radius: 14, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct FFSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ffHeadline)
            .foregroundStyle(FFColor.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Shaped containers

struct FFPill<Content: View>: View {
    let isFilled: Bool
    @ViewBuilder var content: () -> Content
    init(isFilled: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.isFilled = isFilled
        self.content = content
    }
    var body: some View {
        content()
            .font(.ffMicro)
            .padding(.horizontal, FFSpace.m)
            .padding(.vertical, 6)
            .background(isFilled ? FFColor.accentSoft : Color.clear,
                        in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isFilled ? Color.clear : FFColor.border,
                    lineWidth: 1
                )
            )
            .foregroundStyle(isFilled ? FFColor.accent : FFColor.textSecondary)
    }
}

// Decorative gradient glow used on hero screens (auth, league hero card).
struct FFGlow: View {
    var intensity: Double = 1.0
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [FFBrand.cyan.opacity(0.28 * intensity), .clear],
                center: .init(x: 0.2, y: 0.05),
                startRadius: 10, endRadius: 460
            )
            RadialGradient(
                colors: [FFBrand.violet.opacity(0.22 * intensity), .clear],
                center: .init(x: 0.9, y: 0.9),
                startRadius: 10, endRadius: 440
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Brand identity

// The trophy → cyan→violet gradient lockup sampled from the app icon. Use
// these to add brand character on top of the otherwise minimal surface:
// hero headlines, primary CTAs, the refresh indicator, the join code, etc.
// Treat the gradient like the loudest tool in the kit — it works because
// most of the UI stays monochrome.
enum FFBrand {
    static let cyan   = Color(red: 0.27, green: 0.89, blue: 1.00)   // #46e4ff
    static let violet = Color(red: 0.49, green: 0.36, blue: 1.00)   // #7e5cff
}

enum FFGradient {
    static let brand = LinearGradient(
        colors: [FFBrand.cyan, FFBrand.violet],
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )

    static let brandSoft = LinearGradient(
        colors: [FFBrand.cyan.opacity(0.20), FFBrand.violet.opacity(0.20)],
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )

    // Subtle wash for card surfaces on hero screens — barely visible but
    // tints the whole card toward the brand without trampling content.
    static let brandWash = LinearGradient(
        colors: [FFBrand.cyan.opacity(0.08), FFBrand.violet.opacity(0.08)],
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )
}

// The "Tarsa" wordmark + trophy lockup. Same gradient on both icon and
// text so the mark reads as one cohesive unit. `compact` shows just the
// trophy (useful for inline nav titles); the default includes the word.
struct FFBrandMark: View {
    enum Size { case small, medium, large }
    var size: Size = .medium
    var compact: Bool = false
    var showsSubtitle: Bool = false

    private var iconSize: CGFloat {
        switch size {
        case .small:  18
        case .medium: 28
        case .large:  52
        }
    }
    private var textSize: CGFloat {
        switch size {
        case .small:  13
        case .medium: 20
        case .large:  34
        }
    }
    private var subtitleSize: CGFloat {
        switch size {
        case .small:  9
        case .medium: 11
        case .large:  13
        }
    }
    private var spacing: CGFloat {
        switch size {
        case .small:  6
        case .medium: 10
        case .large:  14
        }
    }

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: "trophy.fill")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(FFGradient.brand)
            if !compact {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TARSA")
                        .font(.system(size: textSize, weight: .heavy, design: .rounded))
                        .tracking(size == .large ? 4 : 2.4)
                        .foregroundStyle(FFGradient.brand)
                    if showsSubtitle {
                        Text("FANTASY FOOTBALL")
                            .font(.system(size: subtitleSize, weight: .semibold))
                            .tracking(2)
                            .foregroundStyle(FFColor.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Haptics

// One-line haptic feedback for key actions (draft pick, claim submitted,
// trade responses, failed saves). Kept behind an enum so call sites read
// as intent, not UIKit plumbing.
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
