import SwiftUI

// Stylized front-facing body silhouette that heat-maps a player's injury
// history. Each region fills yellow→red by worst severity and carries a count
// badge. The source data has no laterality, so paired limbs (knee, hand, …)
// light up on both sides equally — see BodyPartGroup.regions / "mirror both
// sides". Region layout is normalized (0…1) and scaled to the available size.
struct BodyHeatMap: View {
    let stats: [BodyRegion: Fantasy.RegionStat]

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                ForEach(Self.regions, id: \.region) { r in
                    let path = r.shape(rect)
                    path.fill(regionFill(r.region))
                    path.stroke(regionStroke(r.region), lineWidth: 1.2)
                }
                ForEach(Self.regions.filter { (stats[$0.region]?.count ?? 0) > 0 },
                        id: \.region) { r in
                    badge(stats[r.region]!.count)
                        .position(x: r.center.x * geo.size.width,
                                  y: r.center.y * geo.size.height)
                }
            }
        }
        .aspectRatio(0.6, contentMode: .fit)
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
    }

    private func regionFill(_ region: BodyRegion) -> Color {
        guard let stat = stats[region], stat.count > 0 else {
            return FFColor.surfaceElevated
        }
        let c = Fantasy.injuryHeatRGB(forSeverity: stat.severity)
        return Color(red: c.r, green: c.g, blue: c.b).opacity(0.92)
    }

    private func regionStroke(_ region: BodyRegion) -> Color {
        (stats[region]?.count ?? 0) > 0
            ? Color.black.opacity(0.22)
            : FFColor.border
    }

    private func badge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(5)
            .frame(minWidth: 22, minHeight: 22)
            .background(Color.black.opacity(0.72), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2))
    }

    // MARK: - Region geometry (normalized 0…1)

    private struct Region {
        let region: BodyRegion
        let center: CGPoint        // normalized centroid for the count badge
        let shape: (CGRect) -> Path
    }

    private static func rounded(
        _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
        radius: Double = 0.5
    ) -> (CGRect) -> Path {
        { rect in
            let r = CGRect(
                x: rect.minX + x0 * rect.width,
                y: rect.minY + y0 * rect.height,
                width: (x1 - x0) * rect.width,
                height: (y1 - y0) * rect.height
            )
            return Path(roundedRect: r, cornerRadius: min(r.width, r.height) * radius)
        }
    }

    private static func ellipse(
        _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double
    ) -> (CGRect) -> Path {
        { rect in
            let r = CGRect(
                x: rect.minX + x0 * rect.width,
                y: rect.minY + y0 * rect.height,
                width: (x1 - x0) * rect.width,
                height: (y1 - y0) * rect.height
            )
            return Path(ellipseIn: r)
        }
    }

    private static let regions: [Region] = [
        Region(region: .head,          center: CGPoint(x: 0.50, y: 0.075),
               shape: ellipse(0.43, 0.01, 0.57, 0.14)),
        Region(region: .leftShoulder,  center: CGPoint(x: 0.355, y: 0.185),
               shape: rounded(0.29, 0.15, 0.42, 0.215, radius: 0.45)),
        Region(region: .rightShoulder, center: CGPoint(x: 0.645, y: 0.185),
               shape: rounded(0.58, 0.15, 0.71, 0.215, radius: 0.45)),
        Region(region: .upperBody,     center: CGPoint(x: 0.50, y: 0.255),
               shape: rounded(0.39, 0.175, 0.61, 0.335, radius: 0.25)),
        Region(region: .lowerBody,     center: CGPoint(x: 0.50, y: 0.395),
               shape: rounded(0.40, 0.335, 0.60, 0.455, radius: 0.22)),
        Region(region: .leftArm,       center: CGPoint(x: 0.305, y: 0.315),
               shape: rounded(0.26, 0.205, 0.35, 0.43, radius: 0.5)),
        Region(region: .rightArm,      center: CGPoint(x: 0.695, y: 0.315),
               shape: rounded(0.65, 0.205, 0.74, 0.43, radius: 0.5)),
        Region(region: .leftHand,      center: CGPoint(x: 0.295, y: 0.465),
               shape: rounded(0.25, 0.435, 0.34, 0.505, radius: 0.45)),
        Region(region: .rightHand,     center: CGPoint(x: 0.705, y: 0.465),
               shape: rounded(0.66, 0.435, 0.75, 0.505, radius: 0.45)),
        Region(region: .leftUpperLeg,  center: CGPoint(x: 0.445, y: 0.535),
               shape: rounded(0.40, 0.455, 0.49, 0.62, radius: 0.45)),
        Region(region: .rightUpperLeg, center: CGPoint(x: 0.555, y: 0.535),
               shape: rounded(0.51, 0.455, 0.60, 0.62, radius: 0.45)),
        Region(region: .leftKnee,      center: CGPoint(x: 0.445, y: 0.65),
               shape: rounded(0.405, 0.62, 0.485, 0.68, radius: 0.5)),
        Region(region: .rightKnee,     center: CGPoint(x: 0.555, y: 0.65),
               shape: rounded(0.515, 0.62, 0.595, 0.68, radius: 0.5)),
        Region(region: .leftLowerLeg,  center: CGPoint(x: 0.445, y: 0.765),
               shape: rounded(0.41, 0.68, 0.485, 0.85, radius: 0.5)),
        Region(region: .rightLowerLeg, center: CGPoint(x: 0.555, y: 0.765),
               shape: rounded(0.515, 0.68, 0.59, 0.85, radius: 0.5)),
        Region(region: .leftFoot,      center: CGPoint(x: 0.44, y: 0.875),
               shape: rounded(0.38, 0.85, 0.49, 0.905, radius: 0.4)),
        Region(region: .rightFoot,     center: CGPoint(x: 0.56, y: 0.875),
               shape: rounded(0.51, 0.85, 0.62, 0.905, radius: 0.4)),
    ]
}

// Yellow→red scale legend for the heat map.
struct BodyHeatLegend: View {
    var body: some View {
        HStack(spacing: FFSpace.s) {
            Text("MILD").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            LinearGradient(
                colors: [
                    heat(1), heat(2), heat(3), heat(4),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 8)
            .clipShape(Capsule())
            Text("SEVERE").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
        }
    }

    private func heat(_ severity: Int) -> Color {
        let c = Fantasy.injuryHeatRGB(forSeverity: severity)
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

#Preview {
    let stats: [BodyRegion: Fantasy.RegionStat] = [
        .head: .init(count: 1, severity: 4),
        .leftKnee: .init(count: 3, severity: 4),
        .rightKnee: .init(count: 3, severity: 4),
        .upperBody: .init(count: 2, severity: 2),
        .leftLowerLeg: .init(count: 1, severity: 1),
        .rightLowerLeg: .init(count: 1, severity: 1),
        .leftShoulder: .init(count: 2, severity: 3),
        .rightShoulder: .init(count: 2, severity: 3),
    ]
    VStack(spacing: 20) {
        BodyHeatMap(stats: stats)
        BodyHeatLegend()
    }
    .padding()
    .background(FFColor.bg)
}
