import SwiftUI

// Sleeper-grade player profile. Phase 1 surface:
//
//   Header (always visible)  – avatar, name, position/team/#, bio strip,
//                              position-rank pill, trend arrow, bye chip,
//                              next-opponent.
//   Sub-tabs: Overview | Game Log | Splits | Advanced | Matchups
//
// Advanced is a placeholder in Phase 1; gets fleshed out in Phase 3 with
// target share, ADOT, route share, etc.
struct PlayerDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let playerID: String

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case overview = "Overview"
        case gameLog  = "Game Log"
        case splits   = "Splits"
        case advanced = "Advanced"
        case matchups = "Matchups"
        var id: String { rawValue }
    }

    @State private var scoring: Scoring = .ppr
    @State private var section: Section = .overview
    @State private var schedules: [NFLGame] = []
    @State private var snapCounts: [String: [Int: SnapCount]] = [:]
    @State private var rankByID: [String: PositionRank] = [:]
    @State private var dvpByPosition: [String: [String: DvPEntry]] = [:]
    @State private var teamTargets: [String: [Int: Double]] = [:]
    @State private var teamTDs: [String: [Int: Double]] = [:]
    @State private var projection: PlayerProjection? = nil

    private var player: Player? { app.selectedPlayers()[playerID] }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                if let player {
                    ScrollView {
                        VStack(spacing: FFSpace.l) {
                            header(player)
                            if let injury = app.injuries[player.id] {
                                injuryCard(injury)
                            }
                            scoringPicker
                            sectionPicker
                            switch section {
                            case .overview: overviewSection(for: player)
                            case .gameLog:  gameLogSection(for: player)
                            case .splits:   splitsSection(for: player)
                            case .advanced: advancedSection(for: player)
                            case .matchups: matchupsSection(for: player)
                            }
                        }
                        .padding(.horizontal, FFSpace.l)
                        .padding(.top, FFSpace.s)
                        .padding(.bottom, 40)
                    }
                } else {
                    VStack(spacing: FFSpace.s) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(FFColor.textTertiary)
                        Text("Player not found").font(.ffTitle).foregroundStyle(FFColor.textPrimary)
                    }
                }
            }
            .navigationTitle(player?.name ?? "Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
            .task(id: playerID) {
                schedules = await app.schedules(season: app.selectedSeason)
                snapCounts = await app.snapCounts(season: app.selectedSeason)
                rankByID = Fantasy.positionRanks(
                    players: app.selectedPlayers(), scoring: scoring
                )
                let players = app.selectedPlayers()
                teamTargets = Fantasy.teamTargetsPerWeek(players: players)
                teamTDs     = Fantasy.teamTouchdownsPerWeek(players: players)
                // Load DvP for the player's own position only — that's the
                // only matchup we render.
                if let pos = player?.position.uppercased() {
                    let table = await app.dvp(season: app.selectedSeason, position: pos)
                    dvpByPosition[pos] = table
                }
                projection = await app.liveProjection(
                    playerID: playerID, season: app.selectedSeason, scoring: scoring
                )
            }
            .onChange(of: scoring) { _, _ in
                rankByID = Fantasy.positionRanks(
                    players: app.selectedPlayers(), scoring: scoring
                )
                Task {
                    projection = await app.liveProjection(
                        playerID: playerID, season: app.selectedSeason, scoring: scoring
                    )
                }
            }
        }
    }

    // MARK: - Header

    private func header(_ p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(alignment: .top, spacing: FFSpace.l) {
                PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(FFColor.textPrimary)
                    HStack(spacing: 6) {
                        PositionPill(position: p.position)
                        Text(p.team).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                        if let n = p.profile?.jerseyNumber { Text("· #\(n)").font(.ffCaption).foregroundStyle(FFColor.textTertiary) }
                        if let status = p.profile?.status,
                           status.uppercased() != "ACT" && !status.isEmpty {
                            Text("· \(status)").font(.ffMicro).foregroundStyle(FFColor.warning)
                        }
                    }
                    if let strip = bioStrip(p) {
                        Text(strip)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            heroStats(for: p)
        }
        .ffCard()
    }

    private func bioStrip(_ p: Player) -> String? {
        guard let profile = p.profile else { return nil }
        var parts: [String] = []
        if let age = profile.age            { parts.append("\(age) yrs") }
        if let h   = profile.heightDisplay  { parts.append(h) }
        if let w   = profile.weightLb       { parts.append("\(w) lb") }
        if let c   = profile.college        { parts.append(c) }
        if let d   = profile.draftDisplay   { parts.append(d) }
        if let e   = profile.experienceDisplay { parts.append(e) }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " · ")
    }

    private func heroStats(for p: Player) -> some View {
        HStack(spacing: FFSpace.l) {
            if let projection {
                heroStat(
                    label: "PROJ",
                    value: String(format: "%.1f", projection.points),
                    color: FFColor.accent
                )
            }
            if let rank = rankByID[p.id] {
                heroStat(label: "RANK", value: rank.label, color: FFColor.accent)
            }
            heroStat(
                label: "TREND",
                value: trendLabel(games: p.games),
                color: trendColor(games: p.games)
            )
            if let bye = p.profile?.byeWeek {
                heroStat(label: "BYE", value: "W\(bye)")
            }
            if let started = app.mostStarted[p.id] {
                heroStat(
                    label: "STARTED",
                    value: String(format: "%.0f%%", started),
                    color: started >= 90 ? FFColor.accent : FFColor.textPrimary
                )
            }
            if let nextOpp = nextOpponent(for: p) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEXT").ffEyebrow(color: FFColor.textTertiary)
                    HStack(spacing: 4) {
                        Text(nextOpp.label)
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.textPrimary)
                        if let rating = nextOpp.rating, rating != .unknown {
                            MatchupPill(rating: rating, compact: true)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private func heroStat(label: String, value: String, color: Color = FFColor.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value)
                .font(.ffStatSmall)
                .foregroundStyle(color)
        }
    }

    private func trendLabel(games: [Game]) -> String {
        switch Fantasy.trendDirection(games: games, scoring: scoring) {
        case .up:   return "↑ Rising"
        case .flat: return "→ Steady"
        case .down: return "↓ Cooling"
        }
    }
    private func trendColor(games: [Game]) -> Color {
        switch Fantasy.trendDirection(games: games, scoring: scoring) {
        case .up:   return FFColor.positive
        case .flat: return FFColor.textSecondary
        case .down: return FFColor.negative
        }
    }

    // Best-effort: the next scheduled game for this player's team. If we
    // have no schedule data yet, returns nil and the chip is hidden.
    private func nextOpponent(for p: Player) -> (label: String, rating: MatchupRating?)? {
        guard !p.team.isEmpty else { return nil }
        let now = Date()
        guard let g = schedules
            .filter({ g in g.kickoff.map { $0 > now } ?? false })
            .first(where: { $0.home == p.team || $0.away == p.team }) else { return nil }
        let isHome = g.home == p.team
        let opp = isHome ? g.away : g.home
        let label = (isHome ? "vs " : "@ ") + opp
        let rating = MatchupRating.from(
            rank: dvpByPosition[p.position.uppercased()]?[opp]?.rank
        )
        return (label, rating)
    }

    // MARK: - Ranks card (team off vs next opponent def, from MFL)

    @ViewBuilder
    private func ranksCard(for p: Player) -> Self.RanksCardView? {
        let own = app.teamRanks[p.team]
        let oppTeam = nextOpponentTeam(for: p)
        let opp = oppTeam.flatMap { app.teamRanks[$0] }
        // Hide entirely when we have nothing on either side (off-season).
        if own == nil && opp == nil { return nil }
        return RanksCardView(own: own, opp: opp, oppTeam: oppTeam)
    }

    private func nextOpponentTeam(for p: Player) -> String? {
        guard !p.team.isEmpty else { return nil }
        let now = Date()
        guard let g = schedules
            .filter({ g in g.kickoff.map { $0 > now } ?? false })
            .first(where: { $0.home == p.team || $0.away == p.team }) else { return nil }
        return g.home == p.team ? g.away : g.home
    }

    struct RanksCardView: View {
        let own: TeamRanks?
        let opp: TeamRanks?
        let oppTeam: String?

        var body: some View {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("MATCHUP RANKS").ffEyebrow().padding(.leading, FFSpace.s)
                HStack(alignment: .top, spacing: FFSpace.l) {
                    column(title: "OWN OFFENSE",
                           rows: [("Pass", own?.passOffense), ("Rush", own?.rushOffense)])
                    Rectangle().fill(FFColor.border).frame(width: 1, height: 56)
                    column(title: "\(oppTeam ?? "OPP") DEFENSE",
                           rows: [("Pass", opp?.passDefense), ("Rush", opp?.rushDefense)])
                }
                .padding(FFSpace.m)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
            }
        }

        private func column(title: String, rows: [(String, Int?)]) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).ffEyebrow(color: FFColor.textTertiary)
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 6) {
                        Text(row.0).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                        Spacer(minLength: 4)
                        if let r = row.1 {
                            Text("#\(r)")
                                .font(.ffStatSmall)
                                .foregroundStyle(rankColor(r))
                        } else {
                            Text("—").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Green = top 8, yellow = mid, red = bottom 8. Same scale for off and def
        // (1 = best offense and best defense by convention here).
        private func rankColor(_ r: Int) -> Color {
            switch r {
            case ...8:  return FFColor.positive
            case 25...: return FFColor.negative
            default:    return FFColor.warning
            }
        }
    }

    // MARK: - Injury card

    private func injuryCard(_ injury: Injury) -> some View {
        let color: Color = {
            switch injury.status.uppercased() {
            case "OUT", "IR", "INJURED RESERVE", "PUP", "SUSPENDED": return FFColor.negative
            default:                                                  return FFColor.warning
            }
        }()
        return HStack(alignment: .top, spacing: FFSpace.m) {
            Image(systemName: "cross.case.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: FFSpace.s) {
                    Text(injury.status.uppercased())
                        .ffEyebrow(color: color)
                    if let details = injury.details, !details.isEmpty {
                        Text(details)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textSecondary)
                    }
                }
                if let date = injury.expectedReturn {
                    Text("Expected return: \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(FFSpace.m)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Scoring picker (kept from prior version)

    private var scoringPicker: some View {
        HStack(spacing: FFSpace.s) {
            ForEach(Scoring.allCases) { s in
                Button {
                    scoring = s
                } label: {
                    Text(s.label.uppercased())
                        .font(.ffMicro).tracking(0.8)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            scoring == s ? FFColor.accentSoft : Color.clear,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                scoring == s ? FFColor.accent : FFColor.border,
                                lineWidth: 1
                            )
                        )
                        .foregroundStyle(scoring == s ? FFColor.accent : FFColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Section picker

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Section.allCases) { s in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { section = s }
                    } label: {
                        Text(s.rawValue)
                            .font(.ffCaption.bold())
                            .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                            .background(
                                section == s ? FFColor.accent : FFColor.surface,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    section == s ? Color.clear : FFColor.border,
                                    lineWidth: 1
                                )
                            )
                            .foregroundStyle(section == s ? FFColor.bg : FFColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Overview

    private func overviewSection(for p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.l) {
            totalsCard(for: p)
            if let card = ranksCard(for: p) { card }
            if !p.games.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("WEEKLY POINTS").ffEyebrow().padding(.leading, FFSpace.s)
                    WeeklyTrendChart(games: p.games, scoring: scoring)
                        .padding(FFSpace.m)
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.border, lineWidth: 1)
                        )
                }
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("WEEKLY DISTRIBUTION").ffEyebrow().padding(.leading, FFSpace.s)
                    PositionDistributionChart(games: p.games, scoring: scoring)
                        .padding(FFSpace.m)
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.border, lineWidth: 1)
                        )
                }
                bestWorstCard(for: p)
            }
        }
    }

    private func totalsCard(for p: Player) -> some View {
        let t = Fantasy.seasonTotals(p.games)
        let pts = t.points(scoring: scoring)
        let gp = max(t.gamesPlayed, 1)
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SEASON").ffEyebrow(color: FFColor.textTertiary)
                    Text(Fantasy.round2(pts).fpString)
                        .font(.ffStatLarge)
                        .foregroundStyle(FFColor.textPrimary)
                    Text("\(Fantasy.round2(pts / Double(gp)).fpString) per game")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
            }
            Rectangle().fill(FFColor.border).frame(height: 1)
            statsGrid(t)
        }
        .ffCard(padding: FFSpace.l)
    }

    private func statsGrid(_ t: SeasonTotals) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: FFSpace.m) {
            stat("GP", "\(t.gamesPlayed)")
            stat("PASS YD", t.passingYards.statString)
            stat("PASS TD", t.passingTDs.statString)
            stat("INT", t.passingInterceptions.statString)
            stat("RUSH YD", t.rushingYards.statString)
            stat("RUSH TD", t.rushingTDs.statString)
            stat("REC", t.receptions.statString)
            stat("REC YD", t.receivingYards.statString)
            stat("REC TD", t.receivingTDs.statString)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
            Text(label).font(.ffMicro).tracking(0.6).foregroundStyle(FFColor.textTertiary)
        }
    }

    private func bestWorstCard(for p: Player) -> some View {
        let sorted = p.games.sorted { $0.points(scoring: scoring) > $1.points(scoring: scoring) }
        let best = sorted.first
        let worst = sorted.last
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("SEASON HIGHS / LOWS").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                if let g = best { highLowRow("Best", game: g, color: FFColor.positive) }
                if let g = worst, g.id != best?.id { highLowRow("Worst", game: g, color: FFColor.negative) }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func highLowRow(_ label: String, game: Game, color: Color) -> some View {
        HStack {
            Text(label.uppercased()).ffEyebrow(color: color).frame(width: 60, alignment: .leading)
            Text("Week \(game.week)")
                .font(.ffBody).foregroundStyle(FFColor.textPrimary)
            Text("vs \(game.opponent)").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            Spacer()
            Text(game.points(scoring: scoring).fpString)
                .font(.ffStatMedium)
                .foregroundStyle(color)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    // MARK: - Game Log

    private func gameLogSection(for p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("GAME LOG").ffEyebrow().padding(.leading, FFSpace.s)
            if p.games.isEmpty {
                Text("No games played yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            } else {
                VStack(spacing: 0) {
                    ForEach(p.games.sorted { $0.week < $1.week }) { g in
                        gameRow(g, snap: snapCounts[p.id]?[g.week])
                    }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
            }
        }
    }

    private func gameRow(_ g: Game, snap: SnapCount?) -> some View {
        let pts = g.points(scoring: scoring)
        return HStack(alignment: .top, spacing: FFSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Week \(g.week)")
                    .font(.ffBody.weight(.semibold))
                    .foregroundStyle(FFColor.textPrimary)
                Text(g.opponent.isEmpty ? " " : "vs \(g.opponent)")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                if let snap, snap.offensePct > 0 {
                    Text("\(Int(snap.offensePct))% snaps")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if g.receivingYards > 0 || g.receptions > 0 {
                    Text("\(g.receptions.statString) rec · \(g.receivingYards.statString) yd · \(g.receivingTDs.statString) TD")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if g.rushingYards > 0 || g.carries > 0 {
                    Text("\(g.carries.statString) car · \(g.rushingYards.statString) yd · \(g.rushingTDs.statString) TD")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if g.passingYards > 0 || g.attempts > 0 {
                    Text("\(Int(g.completions))/\(Int(g.attempts)) · \(g.passingYards.statString) yd · \(g.passingTDs.statString) TD · \(g.passingInterceptions.statString) INT")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if g.targets > 0 {
                    Text("\(Int(g.targets)) tgt")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Text(pts.fpString)
                .font(.ffStatMedium)
                .foregroundStyle(FFColor.textPrimary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    // MARK: - Splits

    private func splitsSection(for p: Player) -> some View {
        // Home/away derived from the schedule rows for this season.
        let schedByGameTeams = Dictionary(uniqueKeysWithValues:
            schedules.map { ("\($0.season)-\($0.week)-\($0.home)-\($0.away)", $0) })
        var home: [Game] = []
        var away: [Game] = []
        for g in p.games {
            // Try both team orderings since we only know p's team + opponent.
            let kHome = "\(g.season)-\(g.week)-\(g.team)-\(g.opponent)"
            let kAway = "\(g.season)-\(g.week)-\(g.opponent)-\(g.team)"
            if schedByGameTeams[kHome] != nil { home.append(g) }
            else if schedByGameTeams[kAway] != nil { away.append(g) }
        }
        // If schedule isn't loaded yet, fall back to "all in one bucket".
        let homeAvg = avgPoints(home)
        let awayAvg = avgPoints(away)
        let allAvg  = avgPoints(p.games)

        return VStack(alignment: .leading, spacing: FFSpace.l) {
            splitCard(title: "HOME / AWAY", rows: [
                ("Home", home.count, homeAvg),
                ("Away", away.count, awayAvg),
                ("Combined", p.games.count, allAvg),
            ])
            // Monthly buckets — weeks 1-4 ≈ Sep, 5-8 ≈ Oct, 9-12 ≈ Nov, 13-18 ≈ Dec/Jan.
            let buckets: [(String, ClosedRange<Int>)] = [
                ("Sep (W1-4)",   1...4),
                ("Oct (W5-8)",   5...8),
                ("Nov (W9-12)",  9...12),
                ("Dec+ (W13+)", 13...22),
            ]
            let monthly = buckets.map { label, range -> (String, Int, Double) in
                let g = p.games.filter { range.contains($0.week) }
                return (label, g.count, avgPoints(g))
            }
            splitCard(title: "MONTHLY", rows: monthly)
        }
    }

    private func avgPoints(_ games: [Game]) -> Double {
        guard !games.isEmpty else { return 0 }
        let total = games.reduce(0.0) { $0 + $1.points(scoring: scoring) }
        return Fantasy.round2(total / Double(games.count))
    }

    private func splitCard(title: String, rows: [(String, Int, Double)]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(title).ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let (label, gp, avg) = rows[i]
                    HStack {
                        Text(label).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text("\(gp) GP")
                            .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                            .frame(width: 60, alignment: .trailing)
                        Text("\(avg.fpString)/g")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                    .ffHairlineBottom()
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Advanced (Phase 3)

    private func advancedSection(for p: Player) -> some View {
        let rows = Fantasy.weeklyAdvanced(
            player: p, snapMap: snapCounts[p.id],
            teamTargets: teamTargets, teamTouchdowns: teamTDs
        )
        // Season aggregates for the summary card on top.
        let totalTargets = rows.reduce(0.0) { $0 + $1.targets }
        let totalCarries = rows.reduce(0.0) { $0 + $1.carries }
        let snapAvg = avgNonNil(rows.compactMap { $0.snapPct })
        let tshareAvg = avgNonNil(rows.compactMap { $0.targetShare })
        let tdshareAvg = avgNonNil(rows.compactMap { $0.tdShare })
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            VStack(alignment: .leading, spacing: FFSpace.m) {
                Text("SEASON USAGE").ffEyebrow().padding(.leading, FFSpace.s)
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: FFSpace.m) {
                    statCell("SNAP %",       snapAvg.map { "\(Int($0))%" } ?? "—")
                    statCell("TGT SHARE",    tshareAvg.map { pctString($0) } ?? "—")
                    statCell("TD SHARE",     tdshareAvg.map { pctString($0) } ?? "—")
                    statCell("TARGETS",      totalTargets.statString)
                    statCell("CARRIES",      totalCarries.statString)
                    statCell("YDS / TGT",
                             totalTargets > 0
                             ? Fantasy.round2(rows.reduce(0.0) { $0 + Double($1.targets) * ($1.yardsPerTarget ?? 0) } / totalTargets).fpString
                             : "—")
                }
            }
            .ffCard(padding: FFSpace.l)

            if !rows.isEmpty {
                weeklyAdvancedTable(rows)
            }
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
            Text(label).font(.ffMicro).tracking(0.6).foregroundStyle(FFColor.textTertiary)
        }
    }

    private func weeklyAdvancedTable(_ rows: [Fantasy.WeeklyAdvanced]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("WEEKLY USAGE").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                // Header row
                HStack {
                    Text("WK").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 32, alignment: .leading)
                    Text("SNAP").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 48, alignment: .trailing)
                    Text("TGT").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 40, alignment: .trailing)
                    Text("TGT %").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 56, alignment: .trailing)
                    Text("CAR").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 40, alignment: .trailing)
                    Text("Y/T").ffEyebrow(color: FFColor.textTertiary)
                        .frame(width: 48, alignment: .trailing)
                    Spacer()
                }
                .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                ForEach(rows, id: \.week) { r in
                    HStack {
                        Text("\(r.week)")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                            .frame(width: 32, alignment: .leading)
                        Text(r.snapPct.map { "\(Int($0))%" } ?? "—")
                            .font(.ffStatSmall).foregroundStyle(snapColor(r.snapPct))
                            .frame(width: 48, alignment: .trailing)
                        Text(r.targets > 0 ? Int(r.targets).description : "—")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(r.targetShare.map { pctString($0) } ?? "—")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                            .frame(width: 56, alignment: .trailing)
                        Text(r.carries > 0 ? Int(r.carries).description : "—")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(r.yardsPerTarget.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                            .frame(width: 48, alignment: .trailing)
                        Spacer()
                    }
                    .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                    .ffHairlineBottom()
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
            Text("Snap %, targets, and shares only. Advanced metrics like ADOT and air-yards land when next-gen-stats ingestion is wired.")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
                .padding(.leading, FFSpace.s)
        }
    }

    private func snapColor(_ pct: Double?) -> Color {
        guard let pct else { return FFColor.textTertiary }
        if pct >= 75 { return FFColor.positive }
        if pct >= 50 { return FFColor.textPrimary }
        if pct >= 25 { return FFColor.warning }
        return FFColor.negative
    }

    private func avgNonNil(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func pctString(_ v: Double) -> String {
        // Target/TD shares are 0..1; render 0..100%.
        let pct = v * 100
        return String(format: "%.0f%%", pct)
    }

    // MARK: - Matchups (career history vs each opponent)

    private func matchupsSection(for p: Player) -> some View {
        // Group all games (this season only — historical seasons aren't
        // loaded yet) by opponent and compute totals.
        let groups = Dictionary(grouping: p.games, by: { $0.opponent })
            .map { opp, games -> (opp: String, gp: Int, avg: Double, best: Double) in
                let avg = games.reduce(0.0) { $0 + $1.points(scoring: scoring) } / Double(games.count)
                let best = games.map { $0.points(scoring: scoring) }.max() ?? 0
                return (opp, games.count, Fantasy.round2(avg), Fantasy.round2(best))
            }
            .sorted { $0.avg > $1.avg }
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("VS OPPONENT (this season)").ffEyebrow().padding(.leading, FFSpace.s)
            if groups.isEmpty {
                Text("No matchups yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("OPP").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 50, alignment: .leading)
                        Spacer()
                        Text("GP").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 40, alignment: .trailing)
                        Text("AVG").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 60, alignment: .trailing)
                        Text("BEST").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                    ForEach(groups, id: \.opp) { g in
                        HStack {
                            Text(g.opp).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                                .frame(width: 50, alignment: .leading)
                            Spacer()
                            Text("\(g.gp)")
                                .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                            Text(g.avg.fpString)
                                .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                                .frame(width: 60, alignment: .trailing)
                            Text(g.best.fpString)
                                .font(.ffStatSmall).foregroundStyle(FFColor.accent)
                                .frame(width: 60, alignment: .trailing)
                        }
                        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                        .ffHairlineBottom()
                    }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
            }
        }
    }
}
