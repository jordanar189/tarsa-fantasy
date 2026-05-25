import Foundation

// Pure, framework-free injury-history analysis: maps nflverse body-part
// strings to coarse regions, collapses weekly report snapshots into distinct
// injury events, and aggregates them per body region for the heat map. No I/O
// — same domain layer as Fantasy.swift, and the place to unit-test this logic.
extension Fantasy {

    // Aggregated injury load at one drawable region.
    struct RegionStat: Hashable, Sendable {
        var count: Int      // number of distinct injury events
        var severity: Int   // worst severity seen, 1 (mild) … 4 (severe)
    }

    // Map a free-text nflverse injury report to a coarse body-part group.
    // Returns nil for non-localized reports (illness, rest, undisclosed, etc.)
    // so they're still listed but not placed on the body map. Order matters:
    // more specific tokens are checked before generic ones.
    static func bodyPartGroup(from detail: String?) -> BodyPartGroup? {
        guard let raw = detail?.lowercased(), !raw.isEmpty else { return nil }
        func has(_ tokens: String...) -> Bool { tokens.contains { raw.contains($0) } }

        if has("concussion", "head", "neck", "jaw", "face", "eye", "nose", "skull") { return .head }
        if has("shoulder", "clavicle", "collarbone", "rotator", "ac joint")         { return .shoulder }
        if has("hand", "finger", "thumb", "wrist")                                  { return .hand }
        if has("elbow", "forearm", "bicep", "tricep", "arm")                        { return .arm }
        if has("knee", "acl", "mcl", "pcl", "lcl", "meniscus", "patella")           { return .knee }
        if has("hamstring", "quad", "thigh", "femur")                               { return .upperLeg }
        if has("ankle", "calf", "shin", "achilles", "tibia", "fibula", "lower leg") { return .lowerLeg }
        if has("foot", "toe", "heel", "plantar", "metatarsal")                      { return .foot }
        if has("hip", "groin", "pelvis", "glute")                                   { return .lowerBody }
        if has("back", "spine", "rib", "chest", "abdomen", "abdominal", "oblique",
               "core", "pectoral", "lat", "torso", "sternum")                       { return .upperBody }
        return nil
    }

    // 1 (mild) … 4 (severe). Drives the yellow→red gradient and event sorting.
    static func injurySeverity(forStatus status: String) -> Int {
        switch status.uppercased() {
        case "IR", "INJURED RESERVE", "PUP", "NFI", "SUSPENDED", "SUS": return 4
        case "OUT":                                                     return 3
        case "DOUBTFUL":                                                return 2
        case "QUESTIONABLE":                                            return 1
        default:                                                        return 1
        }
    }

    // Collapse weekly injury_history rows into distinct events. Rows for the
    // same body part within a season merge unless the week gap exceeds 2 (a bye
    // can drop one weekly report), which starts a new event. The worst status
    // seen across the run becomes the event's severity. Sorted newest-first.
    static func injuryEvents(from rows: [InjuryHistoryRow]) -> [InjuryEvent] {
        struct Key: Hashable { let season: Int; let detail: String }
        var buckets: [Key: [InjuryHistoryRow]] = [:]
        for r in rows {
            let detail = (r.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let norm = detail.isEmpty ? "__undisclosed__" : detail.lowercased()
            buckets[Key(season: r.season, detail: norm), default: []].append(r)
        }

        var events: [InjuryEvent] = []
        for (_, group) in buckets {
            let sorted = group.sorted { $0.week < $1.week }
            var runStart = 0
            while runStart < sorted.count {
                var runEnd = runStart
                while runEnd + 1 < sorted.count,
                      sorted[runEnd + 1].week - sorted[runEnd].week <= 2 {
                    runEnd += 1
                }
                let run = Array(sorted[runStart...runEnd])
                let worst = run.max {
                    injurySeverity(forStatus: $0.status) < injurySeverity(forStatus: $1.status)
                }!
                let display = run
                    .compactMap { row -> String? in
                        let d = (row.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return d.isEmpty ? nil : d
                    }
                    .first ?? "Undisclosed"
                events.append(InjuryEvent(
                    group: bodyPartGroup(from: display),
                    rawDetail: display,
                    season: run.first!.season,
                    startWeek: run.first!.week,
                    endWeek: run.last!.week,
                    worstStatus: worst.status,
                    severity: injurySeverity(forStatus: worst.status)
                ))
                runStart = runEnd + 1
            }
        }
        return events.sorted {
            $0.season != $1.season ? $0.season > $1.season : $0.startWeek > $1.startWeek
        }
    }

    // Per-region aggregation for the heat map. Each event contributes to ALL
    // of its group's regions (both L/R for paired limbs — "mirror both sides").
    // count = number of events at that region; severity = the worst event's.
    static func injuryRegionStats(from events: [InjuryEvent]) -> [BodyRegion: RegionStat] {
        var out: [BodyRegion: RegionStat] = [:]
        for e in events {
            guard let group = e.group else { continue }
            for region in group.regions {
                var stat = out[region] ?? RegionStat(count: 0, severity: 0)
                stat.count += 1
                stat.severity = max(stat.severity, e.severity)
                out[region] = stat
            }
        }
        return out
    }

    // Yellow → red heat color for a severity level. Fixed RGB (vivid enough to
    // read in both light and dark mode) so the gradient is independent of the
    // dynamic palette.
    static func injuryHeatRGB(forSeverity severity: Int) -> (r: Double, g: Double, b: Double) {
        let t = max(0, min(1, Double(severity - 1) / 3.0))   // 0 = mild, 1 = severe
        return (0.97, 0.80 - 0.50 * t, 0.20 - 0.06 * t)
    }
}
