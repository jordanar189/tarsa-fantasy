import SwiftUI

// Shared geometry helpers + the static field background. Keeps coordinate
// math in one place so the play overlay can layer arrows/markers on top
// without re-implementing the projection.
//
// Field coordinate system (yards, regulation NFL):
//   x: 0..120  — 0 = posteam's own end-zone back line, 120 = opponent's
//                back line. End zones are 0..10 and 110..120.
//   y: 0..53.33 — bottom..top sideline.
//
// The field is always rendered so the team with the ball attacks RIGHT —
// when possession changes, the field is flipped horizontally so "ball
// moves right = good things happen" stays a stable mental model.

struct FieldGeometry {
    static let length: Double   = 120
    static let width:  Double   = 53.33
    static let endZoneDepth: Double = 10

    let viewSize: CGSize

    var scale: CGFloat {
        let sx = viewSize.width  / Self.length
        let sy = viewSize.height / Self.width
        return min(sx, sy)
    }

    var renderedSize: CGSize {
        CGSize(width: Self.length * scale, height: Self.width * scale)
    }

    var origin: CGPoint {
        // Center the field within the available view if scale was clamped.
        CGPoint(
            x: (viewSize.width  - renderedSize.width)  / 2,
            y: (viewSize.height - renderedSize.height) / 2
        )
    }

    /// Map yard coordinates to a view-space point.
    func point(x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: origin.x + CGFloat(x) * scale,
            y: origin.y + CGFloat(y) * scale
        )
    }

    /// Distance in yards expressed in view-space points (useful for stroke widths).
    func yards(_ count: Double) -> CGFloat { CGFloat(count) * scale }

    /// Position of the line of scrimmage, oriented for posteam attacking right.
    /// nflverse `yardline_100` = yards from the opponent's goal line, so
    /// ball_x = 110 - yardline_100 in our oriented field.
    func losX(yardline100: Int?) -> Double? {
        guard let y = yardline100 else { return nil }
        return Double(110 - y)
    }
}

// Static field renderer — colors, lines, numbers, end zones, goal posts.
// One Canvas per orientation; the per-play overlay sits in a separate view.
struct GamecastField: View {
    let posteam: String?
    let defteam: String?
    let teamsMeta: [String: NFLTeamMeta]

    var body: some View {
        GeometryReader { geo in
            let g = FieldGeometry(viewSize: geo.size)
            Canvas { ctx, _ in
                drawTurf(ctx, g: g)
                drawEndZones(ctx, g: g)
                drawYardLines(ctx, g: g)
                drawYardNumbers(ctx, g: g)
                drawHashMarks(ctx, g: g)
                drawSidelines(ctx, g: g)
                drawGoalPosts(ctx, g: g)
            }
        }
        .aspectRatio(FieldGeometry.length / FieldGeometry.width, contentMode: .fit)
    }

    // MARK: - Drawing

    private var turfColor: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.10, green: 0.22, blue: 0.13, alpha: 1)
                : UIColor(red: 0.30, green: 0.55, blue: 0.30, alpha: 1)
        })
    }
    private var stripeColor: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.13, green: 0.27, blue: 0.17, alpha: 1)
                : UIColor(red: 0.34, green: 0.59, blue: 0.34, alpha: 1)
        })
    }
    private var lineColor: Color {
        Color.white.opacity(0.85)
    }

    private func drawTurf(_ ctx: GraphicsContext, g: FieldGeometry) {
        let rect = CGRect(origin: g.origin, size: g.renderedSize)
        ctx.fill(Path(rect), with: .color(turfColor))
        // Alternating 10-yard stripes (cosmetic).
        for tens in stride(from: 10, through: 100, by: 20) {
            let stripe = CGRect(
                x: g.point(x: Double(tens), y: 0).x,
                y: rect.minY,
                width: g.yards(10),
                height: rect.height
            )
            ctx.fill(Path(stripe), with: .color(stripeColor))
        }
    }

    private func drawEndZones(_ ctx: GraphicsContext, g: FieldGeometry) {
        // Left end zone: posteam's own; right end zone: opponent's. Posteam
        // attacks right, so the right end zone is where they want to score.
        let left = CGRect(
            x: g.point(x: 0, y: 0).x,
            y: g.origin.y,
            width: g.yards(10),
            height: g.renderedSize.height
        )
        let right = CGRect(
            x: g.point(x: 110, y: 0).x,
            y: g.origin.y,
            width: g.yards(10),
            height: g.renderedSize.height
        )
        ctx.fill(Path(left),  with: .color(endZoneColor(for: posteam).opacity(0.65)))
        ctx.fill(Path(right), with: .color(endZoneColor(for: defteam).opacity(0.65)))

        // Team abbreviations vertically along each end zone.
        if let p = posteam {
            drawVerticalText(ctx, text: p, at: g.point(x: 5, y: FieldGeometry.width / 2),
                             fontSize: g.yards(4), color: .white)
        }
        if let d = defteam {
            drawVerticalText(ctx, text: d, at: g.point(x: 115, y: FieldGeometry.width / 2),
                             fontSize: g.yards(4), color: .white)
        }
    }

    private func endZoneColor(for team: String?) -> Color {
        guard let abbr = team, let meta = teamsMeta[abbr],
              let hex = meta.primaryColor, let c = Color(hex: hex)
        else { return Color.gray }
        return c
    }

    private func drawVerticalText(
        _ ctx: GraphicsContext, text: String,
        at center: CGPoint, fontSize: CGFloat, color: Color
    ) {
        var sub = ctx
        sub.translateBy(x: center.x, y: center.y)
        sub.rotate(by: .degrees(-90))
        let resolved = sub.resolve(Text(text).font(.system(size: fontSize, weight: .heavy))
                                              .foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 1000, height: 1000))
        sub.draw(resolved, at: CGPoint(x: -size.width / 2, y: -size.height / 2),
                 anchor: .topLeading)
    }

    private func drawYardLines(_ ctx: GraphicsContext, g: FieldGeometry) {
        for yd in stride(from: 10, through: 110, by: 5) {
            let p1 = g.point(x: Double(yd), y: 0)
            let p2 = g.point(x: Double(yd), y: FieldGeometry.width)
            var path = Path()
            path.move(to: p1); path.addLine(to: p2)
            let isMajor = yd % 10 == 0
            ctx.stroke(path, with: .color(lineColor),
                       lineWidth: isMajor ? 1.5 : 0.6)
        }
        // Heavier 50.
        let p1 = g.point(x: 60, y: 0), p2 = g.point(x: 60, y: FieldGeometry.width)
        var midPath = Path()
        midPath.move(to: p1); midPath.addLine(to: p2)
        ctx.stroke(midPath, with: .color(lineColor), lineWidth: 2.5)
    }

    private func drawYardNumbers(_ ctx: GraphicsContext, g: FieldGeometry) {
        // Labels at 10, 20, 30, 40, 50, 40, 30, 20, 10 — both sides.
        let labels: [(yd: Int, text: String)] = [
            (20, "10"), (30, "20"), (40, "30"), (50, "40"), (60, "50"),
            (70, "40"), (80, "30"), (90, "20"), (100, "10")
        ]
        for (yd, text) in labels {
            drawNumber(ctx, g: g, text: text, x: Double(yd), y: 8)
            drawNumber(ctx, g: g, text: text, x: Double(yd), y: FieldGeometry.width - 8)
        }
    }

    private func drawNumber(
        _ ctx: GraphicsContext, g: FieldGeometry,
        text: String, x: Double, y: Double
    ) {
        let fontSize = g.yards(3)
        let resolved = ctx.resolve(Text(text)
            .font(.system(size: fontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(lineColor))
        let size = resolved.measure(in: CGSize(width: 100, height: 100))
        let pt = g.point(x: x, y: y)
        ctx.draw(resolved, at: CGPoint(x: pt.x - size.width / 2,
                                       y: pt.y - size.height / 2),
                 anchor: .topLeading)
    }

    private func drawHashMarks(_ ctx: GraphicsContext, g: FieldGeometry) {
        // NCAA-style centered hashes look fine for a schematic. NFL hashes
        // are at 23.58 and 29.75; we'll use those.
        let hashY: [Double] = [23.58, 29.75]
        for yd in stride(from: 10, through: 110, by: 1) where yd % 5 != 0 {
            for h in hashY {
                let p1 = g.point(x: Double(yd), y: h - 0.4)
                let p2 = g.point(x: Double(yd), y: h + 0.4)
                var path = Path()
                path.move(to: p1); path.addLine(to: p2)
                ctx.stroke(path, with: .color(lineColor), lineWidth: 0.6)
            }
        }
    }

    private func drawSidelines(_ ctx: GraphicsContext, g: FieldGeometry) {
        var path = Path()
        path.addRect(CGRect(origin: g.origin, size: g.renderedSize))
        ctx.stroke(path, with: .color(lineColor.opacity(0.6)), lineWidth: 1.5)
        // Goal lines (heavier).
        for x in [10.0, 110.0] {
            var gp = Path()
            gp.move(to:    g.point(x: x, y: 0))
            gp.addLine(to: g.point(x: x, y: FieldGeometry.width))
            ctx.stroke(gp, with: .color(.white), lineWidth: 2.5)
        }
    }

    private func drawGoalPosts(_ ctx: GraphicsContext, g: FieldGeometry) {
        for x in [0.0, 120.0] {
            let base = g.point(x: x, y: FieldGeometry.width / 2)
            // Crossbar at midfield-y, 6 yd wide stylized.
            let crossW = g.yards(6)
            var bar = Path()
            bar.move(to: CGPoint(x: base.x, y: base.y - crossW / 2))
            bar.addLine(to: CGPoint(x: base.x, y: base.y + crossW / 2))
            ctx.stroke(bar, with: .color(.yellow), lineWidth: 1.6)
            // Two uprights extending into the field a bit.
            for dy in [-crossW / 2, crossW / 2] {
                var u = Path()
                u.move(to: CGPoint(x: base.x, y: base.y + dy))
                let dir: CGFloat = x == 0 ? 1 : -1
                u.addLine(to: CGPoint(x: base.x + dir * g.yards(3),
                                       y: base.y + dy))
                ctx.stroke(u, with: .color(.yellow), lineWidth: 1.6)
            }
        }
    }
}

// MARK: - Hex color decoder (small dep-free helper)
private extension Color {
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self = Color(
            red:   Double((v >> 16) & 0xff) / 255,
            green: Double((v >>  8) & 0xff) / 255,
            blue:  Double( v        & 0xff) / 255
        )
    }
}
