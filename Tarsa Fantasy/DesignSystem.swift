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

    // Primary call-to-action button. Full width, accent fill, pill shape.
    func ffPrimaryButton(disabled: Bool = false) -> some View {
        self
            .font(.ffHeadline)
            .foregroundStyle(FFColor.bg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(disabled ? FFColor.borderStrong : FFColor.accent,
                        in: RoundedRectangle(cornerRadius: FFRadius.s))
    }

    // Secondary button — outlined, smaller emphasis.
    func ffSecondaryButton() -> some View {
        self
            .font(.ffHeadline)
            .foregroundStyle(FFColor.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
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
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [FFColor.accent.opacity(0.18), .clear],
                center: .init(x: 0.2, y: 0.1),
                startRadius: 10, endRadius: 420
            )
            RadialGradient(
                colors: [Color(red: 0.49, green: 0.36, blue: 1.0).opacity(0.14), .clear],
                center: .init(x: 0.85, y: 0.85),
                startRadius: 10, endRadius: 400
            )
        }
        .allowsHitTesting(false)
    }
}
