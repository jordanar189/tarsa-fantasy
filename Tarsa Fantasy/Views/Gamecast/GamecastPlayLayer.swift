import SwiftUI

// Animated overlay drawn on top of GamecastField for a single play.
// Each play is classified into one of a handful of visualizations, and
// the overlay animates from `progress = 0` (LOS only) to `progress = 1`
// (final outcome). The parent drives `progress` so it can also be scrubbed.
//
// We render the overlay as a Canvas so a single redraw paints everything,
// which keeps animation cheap.
struct GamecastPlayLayer: View {
    let play: Play
    let posteamAttacking: String?   // who's attacking right (for orientation sanity)
    let progress: Double            // 0...1
    let highlightColor: Color

    var body: some View {
        GeometryReader { geo in
            let g = FieldGeometry(viewSize: geo.size)
            Canvas { ctx, _ in
                drawOverlay(ctx, g: g)
            }
        }
        .aspectRatio(FieldGeometry.length / FieldGeometry.width, contentMode: .fit)
        .allowsHitTesting(false)
    }

    // Stash a few visual constants in one place so the look is consistent
    // across play types.
    private struct Style {
        static let losColor      = Color.yellow.opacity(0.9)
        static let firstDownColor = Color.blue.opacity(0.85)
        static let ballRadius: Double = 1.2   // yards
        static let arrowHeadSize: Double = 1.6
    }

    // MARK: - Top-level dispatch

    private func drawOverlay(_ ctx: GraphicsContext, g: FieldGeometry) {
        // LOS + first-down marker are drawn for every snap that has them.
        if let los = g.losX(yardline100: play.yardline100) {
            drawVerticalLine(ctx, g: g, x: los, color: Style.losColor,
                             width: 2.0, dashed: false)
            if let togo = play.ydstogo, togo > 0 {
                let target = los + Double(togo)
                if target < 110 {
                    drawVerticalLine(ctx, g: g, x: target,
                                     color: Style.firstDownColor,
                                     width: 1.5, dashed: true)
                }
            }
            drawBall(ctx, g: g, at: CGPoint(x: g.point(x: los, y: FieldGeometry.width / 2).x,
                                            y: g.point(x: los, y: FieldGeometry.width / 2).y))
        }

        // Classify + draw the play motion.
        switch classify() {
        case .rush:           drawRush(ctx, g: g)
        case .passComplete:   drawPass(ctx, g: g, complete: true)
        case .passIncomplete: drawPass(ctx, g: g, complete: false)
        case .interception:   drawInterception(ctx, g: g)
        case .sack:           drawSack(ctx, g: g)
        case .fieldGoal:      drawFieldGoal(ctx, g: g)
        case .punt:           drawPunt(ctx, g: g)
        case .penalty:        drawPenalty(ctx, g: g)
        case .kickoff:        drawKickoff(ctx, g: g)
        case .other:          break    // no_play, qb_kneel, qb_spike, etc.
        }

        if play.touchdown == true && progress > 0.85 {
            drawTouchdownGlow(ctx, g: g)
        }
    }

    // MARK: - Classification

    private enum Kind {
        case rush, passComplete, passIncomplete, interception, sack
        case fieldGoal, punt, penalty, kickoff, other
    }

    private func classify() -> Kind {
        if play.interception == true { return .interception }
        if play.sack == true         { return .sack }
        if play.fieldGoalAttempt == true { return .fieldGoal }
        if play.passAttempt == true {
            return play.completePass == true ? .passComplete : .passIncomplete
        }
        if play.rushAttempt == true  { return .rush }
        if play.penalty == true      { return .penalty }
        switch (play.playType ?? "").lowercased() {
        case "punt":    return .punt
        case "kickoff": return .kickoff
        case "run", "rush": return .rush
        case "pass": return play.completePass == true ? .passComplete : .passIncomplete
        case "field_goal": return .fieldGoal
        default: return .other
        }
    }

    // MARK: - Per-play drawings

    private func drawRush(_ ctx: GraphicsContext, g: FieldGeometry) {
        guard let los = g.losX(yardline100: play.yardline100),
              let yards = play.yardsGained else { return }
        let endX = clampX(los + yards)
        let startY = FieldGeometry.width / 2
        let endY = laneY(for: play.runLocation)
        drawAnimatedArrow(ctx, g: g,
                          from: (los, startY), to: (endX, endY),
                          color: highlightColor, dashed: false)
        if let gap = play.runGap {
            drawLabel(ctx, g: g, text: gap.uppercased(),
                      at: (endX, endY - 2), color: .white.opacity(0.85))
        }
    }

    private func drawPass(_ ctx: GraphicsContext, g: FieldGeometry, complete: Bool) {
        guard let los = g.losX(yardline100: play.yardline100) else { return }
        let startY = FieldGeometry.width / 2
        let airYards = play.airYards ?? play.yardsGained ?? 0
        let targetX = clampX(los + airYards)
        let targetY = laneY(for: play.passLocation)

        // Airborne arc (dotted).
        drawAnimatedArc(ctx, g: g,
                        from: (los, startY), to: (targetX, targetY),
                        color: highlightColor.opacity(0.75), dashed: true,
                        proportion: complete ? 0.65 : 1.0)

        if complete {
            // YAC continuation (solid) — animates after the airborne portion.
            let yac = play.yardsAfterCatch ?? max(0, (play.yardsGained ?? 0) - airYards)
            let endX = clampX(targetX + yac)
            drawAnimatedArrow(ctx, g: g,
                              from: (targetX, targetY), to: (endX, targetY),
                              color: highlightColor, dashed: false,
                              startProgress: 0.6)
        } else {
            // Incomplete: terminator X at the target.
            if progress > 0.85 {
                drawIncompleteMarker(ctx, g: g, at: (targetX, targetY))
            }
        }
    }

    private func drawInterception(_ ctx: GraphicsContext, g: FieldGeometry) {
        guard let los = g.losX(yardline100: play.yardline100) else { return }
        let startY = FieldGeometry.width / 2
        let airYards = play.airYards ?? 0
        let intX = clampX(los + airYards)
        let intY = laneY(for: play.passLocation)
        // Airborne pass arc to interception spot.
        drawAnimatedArc(ctx, g: g,
                        from: (los, startY), to: (intX, intY),
                        color: highlightColor.opacity(0.75), dashed: true,
                        proportion: 0.5)
        // Return run in the opposite direction (defteam now has the ball
        // and runs LEFT in our oriented frame).
        let yards = play.yardsGained ?? 0
        let returnEnd = clampX(intX - abs(yards))
        drawAnimatedArrow(ctx, g: g,
                          from: (intX, intY), to: (returnEnd, intY),
                          color: FFColor.negative, dashed: false,
                          startProgress: 0.45)
    }

    private func drawSack(_ ctx: GraphicsContext, g: FieldGeometry) {
        guard let los = g.losX(yardline100: play.yardline100) else { return }
        let endX = clampX(los + (play.yardsGained ?? -6))
        let y = FieldGeometry.width / 2
        drawAnimatedArrow(ctx, g: g,
                          from: (los, y), to: (endX, y),
                          color: FFColor.negative, dashed: false)
    }

    private func drawFieldGoal(_ ctx: GraphicsContext, g: FieldGeometry) {
        guard let los = g.losX(yardline100: play.yardline100) else { return }
        let startY = FieldGeometry.width / 2
        let good = (play.fieldGoalResult ?? "").lowercased() == "made"
        // Kick from 7 yd behind LOS through the right uprights at x=120.
        let kickFromX = max(11, los - 7)
        let endX = good ? 120.0 : 119.0
        let endY = good ? FieldGeometry.width / 2 : FieldGeometry.width / 2 - 6
        drawAnimatedArc(ctx, g: g,
                        from: (kickFromX, startY), to: (endX, endY),
                        color: good ? FFColor.positive : FFColor.warning,
                        dashed: false, proportion: 1.0)
    }

    private func drawPunt(_ ctx: GraphicsContext, g: FieldGeometry) {
        guard let los = g.losX(yardline100: play.yardline100) else { return }
        let yards = play.yardsGained ?? 40   // typical punt distance fallback
        let endX = clampX(los + abs(yards))
        let y = FieldGeometry.width / 2
        drawAnimatedArc(ctx, g: g,
                        from: (los - 5, y), to: (endX, y),
                        color: Color.white.opacity(0.7),
                        dashed: false, proportion: 1.0)
    }

    private func drawKickoff(_ ctx: GraphicsContext, g: FieldGeometry) {
        // Kickoffs in nflverse use yardline_100 = 65 typically.
        let kickFromX = 35.0
        let yards = play.yardsGained ?? 60
        let endX = clampX(kickFromX + abs(yards))
        let y = FieldGeometry.width / 2
        drawAnimatedArc(ctx, g: g,
                        from: (kickFromX, y), to: (endX, y),
                        color: Color.white.opacity(0.7),
                        dashed: false, proportion: 1.0)
    }

    private func drawPenalty(_ ctx: GraphicsContext, g: FieldGeometry) {
        guard let los = g.losX(yardline100: play.yardline100) else { return }
        let y = FieldGeometry.width / 2
        let p = g.point(x: los, y: y)
        let r = g.yards(1.5)
        let flag = CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r)
        ctx.fill(Path(ellipseIn: flag), with: .color(Color.yellow))
        if let yds = play.penaltyYards, yds != 0 {
            drawLabel(ctx, g: g, text: "\(yds) yd",
                      at: (los, y - 3), color: Color.yellow)
        }
    }

    private func drawTouchdownGlow(_ ctx: GraphicsContext, g: FieldGeometry) {
        let endX: Double = 115
        let p = g.point(x: endX, y: FieldGeometry.width / 2)
        let radius = g.yards(8)
        let circle = CGRect(x: p.x - radius, y: p.y - radius,
                            width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: circle),
                 with: .color(FFColor.accent.opacity(0.35)))
        drawLabel(ctx, g: g, text: "TD",
                  at: (endX, FieldGeometry.width / 2),
                  color: .white, weight: .heavy, sizeYd: 6)
    }

    // MARK: - Primitives

    private func drawBall(_ ctx: GraphicsContext, g: FieldGeometry, at p: CGPoint) {
        let r = g.yards(Style.ballRadius)
        let rect = CGRect(x: p.x - r, y: p.y - r / 1.6,
                          width: r * 2, height: r * 2 / 1.6)
        ctx.fill(Path(ellipseIn: rect), with: .color(Color.brown))
        ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 0.6)
    }

    private func drawVerticalLine(
        _ ctx: GraphicsContext, g: FieldGeometry,
        x: Double, color: Color, width: CGFloat, dashed: Bool
    ) {
        let p1 = g.point(x: x, y: 0.6)
        let p2 = g.point(x: x, y: FieldGeometry.width - 0.6)
        var path = Path()
        path.move(to: p1); path.addLine(to: p2)
        var style = StrokeStyle(lineWidth: width, lineCap: .round)
        if dashed { style.dash = [width * 3, width * 2] }
        ctx.stroke(path, with: .color(color), style: style)
    }

    private func drawAnimatedArrow(
        _ ctx: GraphicsContext, g: FieldGeometry,
        from start: (Double, Double), to end: (Double, Double),
        color: Color, dashed: Bool, startProgress: Double = 0.0
    ) {
        let p = arrowProgress(startAt: startProgress)
        let curX = start.0 + (end.0 - start.0) * p
        let curY = start.1 + (end.1 - start.1) * p
        let a = g.point(x: start.0, y: start.1)
        let b = g.point(x: curX, y: curY)
        var path = Path()
        path.move(to: a); path.addLine(to: b)
        var style = StrokeStyle(lineWidth: 3.5, lineCap: .round)
        if dashed { style.dash = [4, 3] }
        ctx.stroke(path, with: .color(color), style: style)
        if p >= 1.0 {
            drawArrowHead(ctx, g: g, at: (end.0, end.1),
                          dx: end.0 - start.0, dy: end.1 - start.1, color: color)
        }
    }

    private func drawAnimatedArc(
        _ ctx: GraphicsContext, g: FieldGeometry,
        from start: (Double, Double), to end: (Double, Double),
        color: Color, dashed: Bool, proportion: Double
    ) {
        // Render an arc by sampling a parabolic path; height ~ 1/4 distance.
        let segments = 40
        let totalProgress = min(progress / proportion, 1.0)
        let visibleSegments = max(1, Int(Double(segments) * totalProgress))
        let dx = end.0 - start.0
        let dy = end.1 - start.1
        let arcHeight = max(2.0, abs(dx) / 5.0)
        var path = Path()
        for i in 0...visibleSegments {
            let t = Double(i) / Double(segments)
            let xy = bezier(t: t, start: start, end: end, arcHeight: arcHeight, dx: dx, dy: dy)
            let pt = g.point(x: xy.0, y: xy.1)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        var style = StrokeStyle(lineWidth: 2.5, lineCap: .round)
        if dashed { style.dash = [3, 3] }
        ctx.stroke(path, with: .color(color), style: style)
        // Endpoint marker once fully drawn.
        if totalProgress >= 1.0 {
            let endPt = g.point(x: end.0, y: end.1)
            ctx.fill(Path(ellipseIn: CGRect(x: endPt.x - 4, y: endPt.y - 4,
                                            width: 8, height: 8)),
                     with: .color(color))
        }
    }

    private func bezier(t: Double, start: (Double, Double), end: (Double, Double),
                        arcHeight: Double, dx: Double, dy: Double) -> (Double, Double) {
        // Quadratic Bezier with the control point lifted toward the top
        // sideline (smaller y on screen = "up" since y grows downward).
        let cx = (start.0 + end.0) / 2
        let cy = (start.1 + end.1) / 2 - arcHeight   // lift
        let u = 1 - t
        let x = u * u * start.0 + 2 * u * t * cx + t * t * end.0
        let y = u * u * start.1 + 2 * u * t * cy + t * t * end.1
        _ = (dx, dy)   // unused — kept for signature symmetry
        return (x, y)
    }

    private func drawArrowHead(
        _ ctx: GraphicsContext, g: FieldGeometry,
        at p: (Double, Double), dx: Double, dy: Double, color: Color
    ) {
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0 else { return }
        let nx = dx / len, ny = dy / len
        // Two side vectors perpendicular to (nx,ny).
        let s = Style.arrowHeadSize
        let leftX  = p.0 - nx * s + ny * s * 0.6
        let leftY  = p.1 - ny * s - nx * s * 0.6
        let rightX = p.0 - nx * s - ny * s * 0.6
        let rightY = p.1 - ny * s + nx * s * 0.6
        let tip = g.point(x: p.0, y: p.1)
        let left = g.point(x: leftX, y: leftY)
        let right = g.point(x: rightX, y: rightY)
        var path = Path()
        path.move(to: tip); path.addLine(to: left); path.addLine(to: right); path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }

    private func drawIncompleteMarker(
        _ ctx: GraphicsContext, g: FieldGeometry, at p: (Double, Double)
    ) {
        let center = g.point(x: p.0, y: p.1)
        let r = g.yards(1.4)
        var path = Path()
        path.move(to: CGPoint(x: center.x - r, y: center.y - r))
        path.addLine(to: CGPoint(x: center.x + r, y: center.y + r))
        path.move(to: CGPoint(x: center.x + r, y: center.y - r))
        path.addLine(to: CGPoint(x: center.x - r, y: center.y + r))
        ctx.stroke(path, with: .color(FFColor.negative), lineWidth: 2.4)
    }

    private func drawLabel(
        _ ctx: GraphicsContext, g: FieldGeometry,
        text: String, at p: (Double, Double),
        color: Color, weight: Font.Weight = .bold, sizeYd: Double = 2.5
    ) {
        let resolved = ctx.resolve(Text(text)
            .font(.system(size: g.yards(sizeYd), weight: weight, design: .rounded))
            .foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 200, height: 200))
        let pt = g.point(x: p.0, y: p.1)
        ctx.draw(resolved, at: CGPoint(x: pt.x - size.width / 2,
                                       y: pt.y - size.height / 2),
                 anchor: .topLeading)
    }

    // MARK: - Helpers

    private func arrowProgress(startAt: Double) -> Double {
        if progress <= startAt { return 0 }
        let span = 1.0 - startAt
        if span <= 0 { return 1.0 }
        return min(1.0, (progress - startAt) / span)
    }

    private func clampX(_ x: Double) -> Double {
        max(0, min(120, x))
    }

    // Map nflverse's left/middle/right to a screen-space lane y.
    private func laneY(for location: String?) -> Double {
        switch location?.lowercased() {
        case "left":   return FieldGeometry.width * 0.78   // bottom-third
        case "right":  return FieldGeometry.width * 0.22   // top-third
        default:       return FieldGeometry.width * 0.50   // middle
        }
    }
}
