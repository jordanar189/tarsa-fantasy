import SwiftUI

// Per-game detail screen surfaced from the NFL Game Center. Three tabs:
//   • Overview — final/in-progress score, game meta (date, kickoff, spread,
//     total, weather/roof/surface), and top fantasy performers per side.
//   • Stats — team-level totals computed from the plays feed (passing,
//     rushing, turnovers, first downs, third-down %, red-zone, EPA).
//   • Play-by-Play — drives as collapsible cards with the plays inside.
//     Default tab on entry; default filter is "Scoring Drives" with every
//     drive dropdown closed.
struct GameDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let game: NFLGame
    var onSelectPlayer: ((String) -> Void)? = nil

    enum Tab: String, CaseIterable, Identifiable {
        case gamecast, overview, stats, plays
        var id: String { rawValue }
        var label: String {
            switch self {
            case .gamecast: return "Gamecast"
            case .overview: return "Overview"
            case .stats:    return "Stats"
            case .plays:    return "Plays"
            }
        }
    }

    @State private var tab: Tab = .gamecast
    @State private var plays: [Play] = []
    @State private var teamsMeta: [String: NFLTeamMeta] = [:]
    @State private var loaded: Bool = false
    @State private var gamecastIndex: Int = 0
    @State private var refreshedGame: NFLGame? = nil

    // The prop is a snapshot from whenever the parent fetched the schedule —
    // refreshes (pull or the in-progress poll) land here so the score header
    // and tabs track the live game.
    private var liveGame: NFLGame { refreshedGame ?? game }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.l) {
                        scoreHeader
                        SegmentedTabPicker(items: Tab.allCases, selection: $tab) {
                            Text($0.label)
                        }
                        switch tab {
                        case .gamecast: GamecastView(game: liveGame, plays: plays,
                                                     loaded: loaded,
                                                     index: $gamecastIndex,
                                                     teamsMeta: teamsMeta)
                        case .overview: OverviewTab(game: liveGame, plays: plays,
                                                    teamsMeta: teamsMeta,
                                                    onSelectPlayer: onSelectPlayer)
                        case .stats:    StatsTab(game: liveGame, plays: plays)
                        case .plays:    PlaysTab(game: liveGame, plays: plays, loaded: loaded)
                        }
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.vertical, FFSpace.l)
                    .padding(.bottom, 40)
                }
                .refreshable { await refresh() }
            }
            // This screen is itself a sheet — host the team profile locally.
            .hostsTeamProfileSheet()
            .navigationTitle("\(game.away) @ \(game.home)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
            .task(id: game.id) {
                await load()
                // No Realtime channel carries plays or the schedule row, so a
                // live game polls while this screen is open. Stops on final.
                while !Task.isCancelled, shouldPoll {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled else { break }
                    await refresh()
                }
            }
        }
    }

    // Poll while the game is live — or scheduled with kickoff imminent/past,
    // so a screen opened just before kickoff picks the game up.
    private var shouldPoll: Bool {
        switch liveGame.status {
        case .inProgress: return true
        case .scheduled:
            guard let k = liveGame.kickoff else { return false }
            return k.timeIntervalSinceNow < 10 * 60
        case .final: return false
        }
    }

    private func load() async {
        async let p = app.plays(gameID: game.id)
        async let t = app.nflTeams()
        let (rawPlays, rawTeams) = await (p, t)
        plays = rawPlays
        teamsMeta = Dictionary(uniqueKeysWithValues: rawTeams.map { ($0.abbr, $0) })
        loaded = true
    }

    // Re-pull the plays feed and the schedule row (score/status).
    private func refresh() async {
        async let p = app.plays(gameID: game.id)
        async let s = app.schedules(season: game.season, forceRefresh: true)
        let (rawPlays, schedule) = await (p, s)
        plays = rawPlays
        if let fresh = schedule.first(where: { $0.id == game.id }) {
            refreshedGame = fresh
        }
    }

    // MARK: - Score header

    private var scoreHeader: some View {
        HStack(alignment: .center, spacing: FFSpace.m) {
            sideBlock(team: liveGame.away, score: liveGame.awayScore, meta: teamsMeta[liveGame.away],
                      winning: winning(side: .away))
            VStack(spacing: 4) {
                statusChip
                if let s = liveGame.homeSpread {
                    Text(formatSpread(s)).font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                }
                if let t = liveGame.total {
                    Text("O/U \(String(format: "%.1f", t))")
                        .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                }
            }
            sideBlock(team: liveGame.home, score: liveGame.homeScore, meta: teamsMeta[liveGame.home],
                      winning: winning(side: .home))
        }
        .ffCard()
    }

    private enum Side { case home, away }
    private func winning(side: Side) -> Bool {
        guard let h = liveGame.homeScore, let a = liveGame.awayScore else { return false }
        return side == .home ? h > a : a > h
    }

    private func sideBlock(team abbr: String, score: Int?, meta: NFLTeamMeta?, winning: Bool) -> some View {
        VStack(spacing: 4) {
            if let url = meta?.logoURL, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFit() }
                    else { Color.clear }
                }
                .frame(width: 44, height: 44)
                .teamLink(abbr)
            }
            Text(abbr)
                .font(.ffCaption.bold())
                .foregroundStyle(FFColor.textPrimary)
                .teamLink(abbr)
            if let s = score, liveGame.status != .scheduled {
                Text("\(s)").font(.ffStatLarge)
                    .foregroundStyle(winning ? FFColor.accent : FFColor.textPrimary)
            } else if let kickoff = liveGame.kickoff {
                Text(kickoff.formatted(.dateTime.month().day()))
                    .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusChip: some View {
        switch liveGame.status {
        case .scheduled:
            if let k = liveGame.kickoff {
                Text(k.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(.ffMicro).foregroundStyle(FFColor.textSecondary)
            } else {
                Text("TBD").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
        case .inProgress:
            Text("LIVE")
                .font(.ffMicro.bold()).tracking(0.8)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(FFColor.live, in: Capsule())
                .foregroundStyle(.white)
        case .final:
            Text("FINAL").font(.ffMicro).tracking(0.8).foregroundStyle(FFColor.textTertiary)
        }
    }

    private func formatSpread(_ s: Double) -> String {
        if s < 0 { return "\(game.home) \(String(format: "%.1f", s))" }
        if s > 0 { return "\(game.away) \(String(format: "%.1f", -s))" }
        return "PK"
    }
}

// MARK: - Overview tab

private struct OverviewTab: View {
    @Environment(AppState.self) private var app
    let game: NFLGame
    let plays: [Play]
    let teamsMeta: [String: NFLTeamMeta]
    var onSelectPlayer: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: FFSpace.l) {
            metaCard
            performersGrid
            if !plays.isEmpty { keyPlaysCard }
        }
    }

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("GAME INFO").ffEyebrow()
            VStack(spacing: 0) {
                if let k = game.kickoff {
                    row(label: "Kickoff",
                        value: k.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                }
                if let t = game.total {
                    row(label: "Total (O/U)", value: String(format: "%.1f", t))
                }
                if let s = game.homeSpread {
                    row(label: "Spread", value: formatSpread(s))
                }
                if let r = game.roof {
                    row(label: "Roof", value: r.capitalized)
                }
                if let s = game.surface {
                    row(label: "Surface", value: s.capitalized)
                }
                if let t = game.tempF {
                    row(label: "Temperature", value: "\(t)°F")
                }
                if let w = game.windMph {
                    row(label: "Wind", value: "\(w) mph")
                }
                if let p = game.precipitation {
                    row(label: "Conditions", value: p.capitalized)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.ffBody).foregroundStyle(FFColor.textSecondary)
            Spacer()
            Text(value).font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func formatSpread(_ s: Double) -> String {
        if s < 0 { return "\(game.home) \(String(format: "%.1f", s))" }
        if s > 0 { return "\(game.away) \(String(format: "%.1f", -s))" }
        return "PK"
    }

    // Top fantasy performers — pulled from the season players snapshot.
    private var performersGrid: some View {
        let players = app.players(season: game.season)
        let homeTop = topPerformers(team: game.home, week: game.week, players: players)
        let awayTop = topPerformers(team: game.away, week: game.week, players: players)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("TOP PERFORMERS").ffEyebrow()
            HStack(alignment: .top, spacing: FFSpace.l) {
                performerColumn(title: game.away, players: awayTop)
                Rectangle().fill(FFColor.border).frame(width: 1)
                performerColumn(title: game.home, players: homeTop)
            }
            .ffCard()
        }
    }

    private func topPerformers(team: String, week: Int, players: [String: Player]) -> [(Player, Double)] {
        players.values
            .filter { $0.team == team }
            .compactMap { p -> (Player, Double)? in
                guard let g = p.games.first(where: { $0.week == week }) else { return nil }
                let pts = g.points(scoring: .ppr)
                return pts > 0 ? (p, pts) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { $0 }
    }

    private func performerColumn(title: String, players: [(Player, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ffCaption.bold()).foregroundStyle(FFColor.textSecondary)
            if players.isEmpty {
                Text("No fantasy production.")
                    .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            } else {
                ForEach(players, id: \.0.id) { player, pts in
                    Button {
                        onSelectPlayer?(player.id)
                    } label: {
                        HStack(spacing: 6) {
                            PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 28)
                            PositionPill(position: player.position)
                            Text(player.name).font(.ffCaption).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                            Spacer()
                            Text(pts.fpString).font(.ffStatSmall).foregroundStyle(FFColor.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onSelectPlayer == nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyPlaysCard: some View {
        let top = topByEPA(count: 3)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("BIGGEST PLAYS (BY EPA)").ffEyebrow()
            if top.isEmpty {
                Text("No EPA data for this game.")
                    .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(top) { p in
                        keyPlayRow(p)
                    }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.s)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
            }
        }
    }

    private func topByEPA(count: Int) -> [Play] {
        plays
            .filter { ($0.epa ?? 0).magnitude >= 0.5 && $0.description?.isEmpty == false }
            .sorted { ($0.epa ?? 0) > ($1.epa ?? 0) }
            .prefix(count)
            .map { $0 }
    }

    private func keyPlayRow(_ p: Play) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let team = p.posteam {
                    Text(team).font(.ffMicro.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(FFColor.surfaceElevated, in: Capsule())
                        .foregroundStyle(FFColor.textSecondary)
                }
                if let q = p.qtr {
                    Text("Q\(q)").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                if let e = p.epa {
                    Text(String(format: "%+.2f EPA", e))
                        .font(.ffMicro.bold())
                        .foregroundStyle(e >= 0 ? FFColor.positive : FFColor.negative)
                }
            }
            Text(p.description ?? "")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textPrimary)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }
}

// MARK: - Stats tab

private struct StatsTab: View {
    let game: NFLGame
    let plays: [Play]

    var body: some View {
        if plays.isEmpty {
            Text("No play-by-play data available yet for this game.")
                .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, FFSpace.xxl)
        } else {
            let home = TeamGameStats.compute(for: game.home, plays: plays)
            let away = TeamGameStats.compute(for: game.away, plays: plays)
            VStack(spacing: FFSpace.l) {
                statsCard(home: home, away: away)
            }
        }
    }

    private func statsCard(home: TeamGameStats, away: TeamGameStats) -> some View {
        VStack(spacing: 0) {
            // Header row with team abbreviations.
            HStack {
                Text(game.away).font(.ffCaption.bold()).foregroundStyle(FFColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Text(game.home).font(.ffCaption.bold()).foregroundStyle(FFColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.vertical, FFSpace.s)
            .background(FFColor.surfaceElevated)
            ForEach(TeamGameStats.displayOrder, id: \.label) { spec in
                statRow(label: spec.label,
                        homeValue: spec.read(home),
                        awayValue: spec.read(away),
                        higherIsBetter: spec.higherIsBetter)
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func statRow(label: String, homeValue: String, awayValue: String,
                         higherIsBetter: Bool) -> some View {
        let homeBetter = compare(homeValue, awayValue, higherIsBetter: higherIsBetter) == .lhs
        let awayBetter = compare(homeValue, awayValue, higherIsBetter: higherIsBetter) == .rhs
        return HStack(spacing: 0) {
            Text(awayValue)
                .font(.ffStatSmall)
                .foregroundStyle(awayBetter ? FFColor.accent : FFColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(label)
                .font(.ffMicro).tracking(0.6)
                .foregroundStyle(FFColor.textTertiary)
            Text(homeValue)
                .font(.ffStatSmall)
                .foregroundStyle(homeBetter ? FFColor.accent : FFColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private enum Cmp { case lhs, rhs, eq }
    private func compare(_ a: String, _ b: String, higherIsBetter: Bool) -> Cmp {
        let na = parseLeadingNumber(a) ?? 0
        let nb = parseLeadingNumber(b) ?? 0
        if na == nb { return .eq }
        let aBetter = higherIsBetter ? na > nb : na < nb
        return aBetter ? .lhs : .rhs
    }

    private func parseLeadingNumber(_ s: String) -> Double? {
        var num = ""
        for ch in s {
            if ch.isNumber || ch == "." || ch == "-" { num.append(ch) }
            else if !num.isEmpty { break }
        }
        return Double(num)
    }
}

// MARK: - Aggregate team stats from plays

private struct TeamGameStats {
    var totalYards: Int = 0
    var passingYards: Int = 0
    var rushingYards: Int = 0
    var firstDowns: Int = 0
    var passAttempts: Int = 0
    var passCompletions: Int = 0
    var rushAttempts: Int = 0
    var sacksTaken: Int = 0
    var interceptions: Int = 0
    var fumblesLost: Int = 0
    var turnovers: Int { interceptions + fumblesLost }
    var penalties: Int = 0
    var penaltyYards: Int = 0
    var thirdDownAtt: Int = 0
    var thirdDownConv: Int = 0
    var fourthDownAtt: Int = 0
    var fourthDownConv: Int = 0
    var redZoneTrips: Int = 0
    var redZoneTDs: Int = 0
    var totalEPA: Double = 0
    var passEPA: Double = 0
    var rushEPA: Double = 0
    var plays: Int = 0

    static func compute(for team: String, plays: [Play]) -> TeamGameStats {
        var s = TeamGameStats()
        var redZoneDrives = Set<Int>()
        var redZoneTDDrives = Set<Int>()
        for p in plays where p.posteam == team {
            s.plays += 1
            s.totalYards += Int(p.yardsGained ?? 0)
            s.totalEPA += p.epa ?? 0
            if p.passAttempt == true {
                s.passAttempts += 1
                s.passingYards += Int(p.yardsGained ?? 0)
                s.passEPA += p.epa ?? 0
                if p.completePass == true { s.passCompletions += 1 }
            } else if p.rushAttempt == true {
                s.rushAttempts += 1
                s.rushingYards += Int(p.yardsGained ?? 0)
                s.rushEPA += p.epa ?? 0
            }
            if p.sack == true { s.sacksTaken += 1 }
            if p.interception == true { s.interceptions += 1 }
            if p.fumbleLost == true { s.fumblesLost += 1 }
            if p.firstDown == true { s.firstDowns += 1 }
            if p.penalty == true {
                s.penalties += 1
                s.penaltyYards += p.penaltyYards ?? 0
            }
            if let down = p.down {
                if down == 3 {
                    s.thirdDownAtt += 1
                    if p.firstDown == true { s.thirdDownConv += 1 }
                } else if down == 4 && p.fieldGoalAttempt != true {
                    s.fourthDownAtt += 1
                    if p.firstDown == true || p.touchdown == true { s.fourthDownConv += 1 }
                }
            }
            if let y = p.yardline100, y <= 20, let d = p.drive {
                redZoneDrives.insert(d)
                if p.touchdown == true { redZoneTDDrives.insert(d) }
            }
        }
        s.redZoneTrips = redZoneDrives.count
        s.redZoneTDs   = redZoneTDDrives.count
        return s
    }

    struct DisplaySpec {
        let label: String
        let read: (TeamGameStats) -> String
        let higherIsBetter: Bool
    }

    static let displayOrder: [DisplaySpec] = [
        .init(label: "TOTAL YARDS",     read: { "\($0.totalYards)" },                 higherIsBetter: true),
        .init(label: "PASS YARDS",      read: { "\($0.passingYards)" },               higherIsBetter: true),
        .init(label: "RUSH YARDS",      read: { "\($0.rushingYards)" },               higherIsBetter: true),
        .init(label: "FIRST DOWNS",     read: { "\($0.firstDowns)" },                 higherIsBetter: true),
        .init(label: "COMP / ATT",      read: { "\($0.passCompletions)/\($0.passAttempts)" }, higherIsBetter: true),
        .init(label: "RUSH ATT",        read: { "\($0.rushAttempts)" },               higherIsBetter: true),
        .init(label: "SACKS ALLOWED",   read: { "\($0.sacksTaken)" },                 higherIsBetter: false),
        .init(label: "TURNOVERS",       read: { "\($0.turnovers)" },                  higherIsBetter: false),
        .init(label: "PENALTIES (YDS)", read: { "\($0.penalties) (\($0.penaltyYards))" }, higherIsBetter: false),
        .init(label: "3RD DOWN",        read: { conv($0.thirdDownConv, $0.thirdDownAtt) }, higherIsBetter: true),
        .init(label: "4TH DOWN",        read: { conv($0.fourthDownConv, $0.fourthDownAtt) }, higherIsBetter: true),
        .init(label: "RED ZONE TD",     read: { conv($0.redZoneTDs, $0.redZoneTrips) }, higherIsBetter: true),
        .init(label: "EPA / PLAY",      read: { epaPer($0.totalEPA, $0.plays) },      higherIsBetter: true),
        .init(label: "PASS EPA",        read: { String(format: "%+.1f", $0.passEPA) }, higherIsBetter: true),
        .init(label: "RUSH EPA",        read: { String(format: "%+.1f", $0.rushEPA) }, higherIsBetter: true),
    ]

    private static func conv(_ a: Int, _ b: Int) -> String {
        if b == 0 { return "0/0" }
        return "\(a)/\(b) (\(Int((Double(a) / Double(b)) * 100))%)"
    }
    private static func epaPer(_ total: Double, _ plays: Int) -> String {
        if plays == 0 { return "0.00" }
        return String(format: "%+.3f", total / Double(plays))
    }
}

// MARK: - Plays tab

private struct PlaysTab: View {
    let game: NFLGame
    let plays: [Play]
    let loaded: Bool

    enum Filter: String, CaseIterable, Identifiable {
        case scoring, all
        var id: String { rawValue }
        var label: String { self == .scoring ? "Scoring Drives" : "All Drives" }
    }

    @State private var filter: Filter = .scoring
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: FFSpace.l) {
            SegmentedTabPicker(items: Filter.allCases, selection: $filter) {
                Text($0.label)
            }
            if !loaded {
                ProgressView().tint(FFColor.accent).padding(.vertical, FFSpace.xxl)
            } else if plays.isEmpty {
                Text("No play-by-play data is available yet for this game.")
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, FFSpace.xxl)
            } else {
                let drives = Drive.buildAll(from: plays)
                let visible = filter == .scoring ? drives.filter(\.isScoring) : drives
                if visible.isEmpty {
                    Text(filter == .scoring
                         ? "No scoring drives in this game."
                         : "No drives recorded.")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textSecondary)
                        .padding(.vertical, FFSpace.xl)
                } else {
                    VStack(spacing: FFSpace.s) {
                        ForEach(visible) { drive in
                            driveCard(drive)
                        }
                    }
                }
            }
        }
    }

    private func driveCard(_ drive: Drive) -> some View {
        let isOpen = expanded.contains(drive.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { expanded.remove(drive.id) } else { expanded.insert(drive.id) }
                }
            } label: {
                driveHeader(drive, isOpen: isOpen)
            }
            .buttonStyle(.plain)
            if isOpen {
                Divider().background(FFColor.border)
                VStack(spacing: 0) {
                    ForEach(drive.plays) { p in
                        playRow(p, drivePosteam: drive.team)
                    }
                }
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(
                    drive.isScoring ? FFColor.accent.opacity(0.4) : FFColor.border,
                    lineWidth: 1
                )
        )
    }

    private func driveHeader(_ drive: Drive, isOpen: Bool) -> some View {
        HStack(spacing: FFSpace.s) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(drive.team ?? "—")
                        .font(.ffMicro.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(FFColor.surfaceElevated, in: Capsule())
                        .foregroundStyle(FFColor.textPrimary)
                    if let q = drive.startQuarter {
                        Text("Q\(q)").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                    }
                    if let clock = drive.startClock {
                        Text(clock).font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                    }
                }
                Text(drive.summary)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
            Spacer()
            Text(drive.resultLabel)
                .font(.ffMicro.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(drive.resultColor.opacity(0.18), in: Capsule())
                .foregroundStyle(drive.resultColor)
            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
    }

    private func playRow(_ p: Play, drivePosteam: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let down = p.down, let togo = p.ydstogo, down > 0 {
                    Text("\(ordinal(down)) & \(togo)")
                        .font(.ffMicro.bold())
                        .foregroundStyle(FFColor.textSecondary)
                }
                if let y = p.yardline100 {
                    Text(formatFieldPosition(yardline100: y, posteam: p.posteam))
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                if let e = p.epa, abs(e) >= 0.5 {
                    Text(String(format: "%+.1f", e))
                        .font(.ffMicro.bold())
                        .foregroundStyle(e >= 0 ? FFColor.positive : FFColor.negative)
                }
                if let yds = p.yardsGained {
                    Text("\(Int(yds)) yd")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Text(p.description ?? "—")
                .font(.ffCaption)
                .foregroundStyle(
                    p.touchdown == true || p.fieldGoalResult == "made"
                        ? FFColor.accent
                        : FFColor.textPrimary
                )
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    // "yardline_100" is the distance from the posteam's opponent's end zone.
    // 25 means posteam is at their own 25 if it's >= 50, or at the opponent's
    // 25 if < 50. nflverse's convention: yardline_100 = yards to the end
    // zone, so 25 = inside opponent's 25, 75 = at own 25.
    private func formatFieldPosition(yardline100 y: Int, posteam: String?) -> String {
        if y == 50 { return "MID" }
        if y < 50, let p = posteam {
            return "\(opponentOf(p))-\(y)"
        }
        if let p = posteam {
            return "\(p)-\(100 - y)"
        }
        return "\(y)"
    }

    private func opponentOf(_ team: String) -> String {
        team == game.home ? game.away : game.home
    }
}

// MARK: - Drive helper

private struct Drive: Identifiable {
    var id: String { "\(team ?? "?")-\(startPlayID)" }
    let team: String?            // posteam owning this drive
    let plays: [Play]
    let startPlayID: Int
    let startQuarter: Int?
    let startClock: String?
    let yardsGained: Int
    let isScoring: Bool
    let resultLabel: String
    let resultColor: Color
    var summary: String {
        var bits: [String] = []
        bits.append("\(plays.count) play\(plays.count == 1 ? "" : "s")")
        bits.append("\(yardsGained) yd")
        return bits.joined(separator: " · ")
    }

    static func buildAll(from plays: [Play]) -> [Drive] {
        // Skip "boundary" play types that nflverse uses for clock events
        // (kickoff, two-minute warning, end of quarter, etc.) — they bloat
        // the drive list without carrying real info.
        let skip: Set<String> = ["kickoff", "no_play", "qb_kneel"]

        // Group by nflverse's `drive` column when populated; otherwise fall
        // back to a possession-change scan.
        let useColumn = plays.contains(where: { $0.drive != nil })
        var groups: [[Play]] = []
        if useColumn {
            let by = Dictionary(grouping: plays.filter { $0.drive != nil },
                                by: { $0.drive! })
            groups = by.keys.sorted().map { by[$0] ?? [] }
        } else {
            var current: [Play] = []
            var lastPosteam: String? = nil
            for p in plays {
                if p.posteam != lastPosteam, !current.isEmpty {
                    groups.append(current); current = []
                }
                current.append(p)
                lastPosteam = p.posteam
            }
            if !current.isEmpty { groups.append(current) }
        }

        return groups.compactMap { raw -> Drive? in
            let filtered = raw.filter { !skip.contains(($0.playType ?? "").lowercased()) }
            guard let first = filtered.first else { return nil }
            let yards = Int(filtered.reduce(0.0) { $0 + ($1.yardsGained ?? 0) })
            let scoring = filtered.contains(where: {
                $0.touchdown == true
                || $0.fieldGoalResult == "made"
                || $0.twoPointAttempt == true
                || $0.extraPointResult == "good"
            })
            let (label, color) = classifyResult(plays: filtered)
            return Drive(
                team: first.posteam,
                plays: filtered,
                startPlayID: first.playID,
                startQuarter: first.qtr,
                startClock: formatClock(first.gameSecondsRemaining),
                yardsGained: yards,
                isScoring: scoring,
                resultLabel: label,
                resultColor: color
            )
        }
    }

    private static func classifyResult(plays: [Play]) -> (String, Color) {
        for p in plays.reversed() {
            if p.touchdown == true   { return ("TD", FFColor.accent) }
            if p.fieldGoalResult == "made" { return ("FG", FFColor.positive) }
            if p.interception  == true { return ("INT", FFColor.negative) }
            if p.fumbleLost    == true { return ("FUM", FFColor.negative) }
            if p.fieldGoalAttempt == true, p.fieldGoalResult != "made" {
                return ("MISS FG", FFColor.warning)
            }
            if (p.playType ?? "").lowercased() == "punt" {
                return ("PUNT", FFColor.textTertiary)
            }
        }
        return ("EOD", FFColor.textTertiary)   // end-of-half/game catch-all
    }

    private static func formatClock(_ secsRemaining: Int?) -> String? {
        guard let s = secsRemaining, s >= 0 else { return nil }
        // game_seconds_remaining is total time left in the game; convert to
        // quarter-clock by mod 900 (15-min quarters).
        let q = s % 900
        let m = q / 60
        let sec = q % 60
        return String(format: "%d:%02d", m, sec)
    }
}
