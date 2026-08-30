import SwiftUI
import Combine

// Preseason game sheet: score header with quarter linescores, scoring
// summary, and the full ESPN box score per team grouped by category. Every
// athlete is listed — including ones with no nflverse id, which is most of a
// preseason fourth quarter — and the ones we know link to their profile.
// Live: the `preseason_updated` broadcast for this game, pull-to-refresh, and
// a 45 s poll while the game is in progress.
struct PreseasonGameView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let game: PreseasonGame

    private enum Side: String, CaseIterable, Identifiable {
        case away, home
        var id: String { rawValue }
    }

    @State private var refreshedGame: PreseasonGame? = nil
    @State private var lines: [PreseasonPlayerLine] = []
    @State private var teamsMeta: [String: NFLTeamMeta] = [:]
    @State private var loaded: Bool = false
    @State private var side: Side = .away

    // The prop is a snapshot from whenever the scoreboard fetched it —
    // refreshes land here so the header tracks the live game.
    private var liveGame: PreseasonGame { refreshedGame ?? game }
    private var sideTeam: String { side == .away ? liveGame.away : liveGame.home }
    private var sideLines: [PreseasonPlayerLine] { lines.filter { $0.team == sideTeam } }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.l) {
                        scoreHeader
                        if !liveGame.scoringPlays.isEmpty { scoringSummary }
                        boxScore
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.vertical, FFSpace.l)
                    .padding(.bottom, 40)
                }
                .refreshable { await refresh() }
            }
            // This screen is itself a sheet — host the profiles locally.
            .hostsPlayerProfileSheet()
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
        }
        .task {
            await load()
            await pollWhileLive()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .preseasonUpdated)
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
        ) { note in
            let ids = note.userInfo?["gameIDs"] as? [String] ?? []
            guard ids.isEmpty || ids.contains(game.id) else { return }
            Task { await refresh() }
        }
    }

    private func load() async {
        async let t = app.nflTeams()
        async let l = app.preseasonBoxScore(gameID: game.id)
        let (teams, box) = await (t, l)
        teamsMeta = Dictionary(uniqueKeysWithValues: teams.map { ($0.abbr, $0) })
        lines = box
        loaded = true
    }

    private func refresh() async {
        async let g = app.preseasonGame(gameID: game.id)
        async let l = app.preseasonBoxScore(gameID: game.id)
        let (fresh, box) = await (g, l)
        if let fresh { refreshedGame = fresh }
        lines = box
        loaded = true
    }

    private var shouldPoll: Bool {
        if liveGame.isLive { return true }
        if liveGame.status == .scheduled, let k = liveGame.kickoff {
            return k.timeIntervalSinceNow < 10 * 60
        }
        return false
    }

    private func pollWhileLive() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            if shouldPoll { await refresh() }
        }
    }

    // MARK: - Header

    private var scoreHeader: some View {
        VStack(spacing: FFSpace.m) {
            HStack(alignment: .center, spacing: FFSpace.s) {
                teamBlock(liveGame.away, score: liveGame.awayScore,
                          isWinning: (liveGame.awayScore ?? 0) > (liveGame.homeScore ?? 0))
                statusBlock
                teamBlock(liveGame.home, score: liveGame.homeScore,
                          isWinning: (liveGame.homeScore ?? 0) > (liveGame.awayScore ?? 0))
            }
            if liveGame.status != .scheduled,
               !(liveGame.awayLinescores.isEmpty && liveGame.homeLinescores.isEmpty) {
                linescore
            }
            HStack(spacing: FFSpace.s) {
                Text(liveGame.weekLabel)
                if let k = liveGame.kickoff {
                    Text("·")
                    Text(k.formatted(date: .abbreviated, time: .shortened))
                }
                if let v = liveGame.venue {
                    Text("·")
                    Text(v).lineLimit(1)
                }
            }
            .font(.ffMicro)
            .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }

    private func teamBlock(_ abbr: String, score: Int?, isWinning: Bool) -> some View {
        let meta = teamsMeta[abbr]
        return VStack(spacing: 4) {
            TeamLogoCircle(url: meta?.logoURL, size: 48)
            Text(abbr)
                .font(.ffCaption.bold())
                .foregroundStyle(FFColor.textPrimary)
                .teamLink(abbr)
            if let s = score, liveGame.status != .scheduled {
                Text("\(s)")
                    .font(.ffStatHero)
                    .foregroundStyle(isWinning && liveGame.status == .final ? FFColor.accent : FFColor.textPrimary)
            } else {
                Text(meta?.fullName ?? "")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusBlock: some View {
        VStack(spacing: 6) {
            switch liveGame.status {
            case .scheduled:
                if let k = liveGame.kickoff {
                    Text(k.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                    Text(k.formatted(date: .omitted, time: .shortened))
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                } else {
                    Text("TBD").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                }
            case .inProgress:
                Text("LIVE")
                    .font(.ffMicro.bold()).tracking(0.8)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(FFColor.live, in: Capsule())
                    .foregroundStyle(.white)
                Text(liveGame.statusDetail ?? "")
                    .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
            case .final:
                Text("FINAL")
                    .font(.ffMicro).tracking(0.8)
                    .foregroundStyle(FFColor.textTertiary)
            case .postponed:
                Text("POSTPONED")
                    .font(.ffMicro).tracking(0.8)
                    .foregroundStyle(FFColor.warning)
            }
        }
        .frame(minWidth: 84)
    }

    // Quarter-by-quarter. Column count follows the longer side so an
    // in-progress game grows a column at a time and overtime shows up as Q5.
    private var linescore: some View {
        let periods = max(liveGame.awayLinescores.count, liveGame.homeLinescores.count, 4)
        return VStack(spacing: 4) {
            linescoreRow(label: "", values: (1...periods).map { $0 <= 4 ? "\($0)" : "OT" }, total: "T",
                         color: FFColor.textTertiary)
            linescoreRow(label: liveGame.away,
                         values: (0..<periods).map { i in
                             i < liveGame.awayLinescores.count ? "\(liveGame.awayLinescores[i])" : "–"
                         },
                         total: liveGame.awayScore.map { "\($0)" } ?? "–",
                         color: FFColor.textPrimary)
            linescoreRow(label: liveGame.home,
                         values: (0..<periods).map { i in
                             i < liveGame.homeLinescores.count ? "\(liveGame.homeLinescores[i])" : "–"
                         },
                         total: liveGame.homeScore.map { "\($0)" } ?? "–",
                         color: FFColor.textPrimary)
        }
        .padding(.horizontal, FFSpace.s)
    }

    private func linescoreRow(label: String, values: [String], total: String, color: Color) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.ffCaption.bold())
                .foregroundStyle(color)
                .frame(width: 44, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Text(v)
                    .font(.ffStatSmall)
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity)
            }
            Text(total)
                .font(.ffStatSmall.weight(.heavy))
                .foregroundStyle(color)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Scoring summary

    private var scoringSummary: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("SCORING").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                ForEach(Array(liveGame.scoringPlays.enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .top, spacing: FFSpace.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.team ?? "")
                                .font(.ffCaption.bold())
                                .foregroundStyle(FFColor.textPrimary)
                            Text(periodLabel(p.period) + (p.clock.map { " \($0)" } ?? ""))
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                        .frame(width: 56, alignment: .leading)
                        Text(p.text)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textSecondary)
                            .lineLimit(2)
                        Spacer(minLength: FFSpace.s)
                        Text("\(p.away ?? 0)–\(p.home ?? 0)")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.textPrimary)
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

    private func periodLabel(_ period: Int?) -> String {
        guard let period else { return "" }
        return period <= 4 ? "Q\(period)" : "OT"
    }

    // MARK: - Box score

    private var boxScore: some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            SegmentedTabPicker(items: Side.allCases, selection: $side) {
                Text($0 == .away ? liveGame.away : liveGame.home)
            }
            if !loaded {
                ProgressView().tint(FFColor.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, FFSpace.xl)
            } else if sideLines.isEmpty {
                Text(liveGame.status == .scheduled ? "Box score arrives at kickoff."
                                                   : "No stats recorded yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            } else {
                ForEach(BoxCategory.allCases) { cat in
                    let rows = cat.rows(sideLines)
                    if !rows.isEmpty {
                        categorySection(cat, rows: rows)
                    }
                }
            }
        }
    }

    private func categorySection(_ cat: BoxCategory, rows: [PreseasonPlayerLine]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(cat.title).ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                ForEach(rows) { line in
                    playerRow(line, stat: cat.statLine(line))
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func playerRow(_ line: PreseasonPlayerLine, stat: String) -> some View {
        HStack(alignment: .center, spacing: FFSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(line.name)
                        .font(.ffBody.weight(.semibold))
                        .foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                    if line.playerID != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
                .playerLink(line.playerID)
                Text(stat)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
            Spacer(minLength: FFSpace.s)
            if let j = line.jersey {
                Text("#\(j)")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }
}

// ESPN's box-score categories, each with its own sort key and one-line
// summary. Order mirrors ESPN's box score.
private enum BoxCategory: String, CaseIterable, Identifiable {
    case passing, rushing, receiving, defense, returns, kicking
    var id: String { rawValue }

    var title: String {
        switch self {
        case .passing:   return "PASSING"
        case .rushing:   return "RUSHING"
        case .receiving: return "RECEIVING"
        case .defense:   return "DEFENSE"
        case .returns:   return "RETURNS"
        case .kicking:   return "KICKING"
        }
    }

    func rows(_ lines: [PreseasonPlayerLine]) -> [PreseasonPlayerLine] {
        switch self {
        case .passing:   return lines.filter(\.hasPassing).sorted { $0.passingYards > $1.passingYards }
        case .rushing:   return lines.filter(\.hasRushing).sorted { $0.rushingYards > $1.rushingYards }
        case .receiving: return lines.filter(\.hasReceiving).sorted { $0.receivingYards > $1.receivingYards }
        case .defense:   return lines.filter(\.hasDefense).sorted { $0.defTacklesTotal > $1.defTacklesTotal }
        case .returns:   return lines.filter(\.hasReturns)
                                     .sorted { $0.kickReturnYards + $0.puntReturnYards > $1.kickReturnYards + $1.puntReturnYards }
        case .kicking:   return lines.filter(\.hasKicking).sorted { $0.fgMade > $1.fgMade }
        }
    }

    func statLine(_ l: PreseasonPlayerLine) -> String {
        switch self {
        case .passing:
            return "\(Int(l.completions))/\(Int(l.attempts)) · \(l.passingYards.statString) yd · \(l.passingTDs.statString) TD · \(l.passingInterceptions.statString) INT"
        case .rushing:
            return "\(l.carries.statString) car · \(l.rushingYards.statString) yd · \(l.rushingTDs.statString) TD · long \(l.rushingLong.statString)"
        case .receiving:
            return "\(l.receptions.statString) rec · \(l.receivingYards.statString) yd · \(l.receivingTDs.statString) TD · \(l.targets.statString) tgt"
        case .defense:
            var parts = ["\(l.defTacklesTotal.statString) tkl (\(l.defTacklesSolo.statString) solo)"]
            if l.defSacks > 0 { parts.append("\(l.defSacks.statString) sck") }
            if l.defTacklesForLoss > 0 { parts.append("\(l.defTacklesForLoss.statString) tfl") }
            if l.defPassDefended > 0 { parts.append("\(l.defPassDefended.statString) pd") }
            if l.defInterceptions > 0 { parts.append("\(l.defInterceptions.statString) int") }
            if l.defTDs > 0 { parts.append("\(l.defTDs.statString) TD") }
            return parts.joined(separator: " · ")
        case .returns:
            var parts: [String] = []
            if l.kickReturns > 0 { parts.append("KR \(l.kickReturns.statString)-\(l.kickReturnYards.statString)" + (l.kickReturnTDs > 0 ? " · \(l.kickReturnTDs.statString) TD" : "")) }
            if l.puntReturns > 0 { parts.append("PR \(l.puntReturns.statString)-\(l.puntReturnYards.statString)" + (l.puntReturnTDs > 0 ? " · \(l.puntReturnTDs.statString) TD" : "")) }
            return parts.joined(separator: " · ")
        case .kicking:
            var parts = ["FG \(l.fgMade.statString)/\(l.fgAtt.statString)"]
            if l.fgLong > 0 { parts.append("long \(l.fgLong.statString)") }
            parts.append("XP \(l.patMade.statString)/\(l.patAtt.statString)")
            return parts.joined(separator: " · ")
        }
    }
}

// Fetches the game row before presenting the sheet — used where only the id
// is at hand (the player profile's preseason page).
struct PreseasonGameLoaderView: View {
    @Environment(AppState.self) private var app
    let gameID: String
    @State private var game: PreseasonGame? = nil
    @State private var failed = false

    var body: some View {
        Group {
            if let game {
                PreseasonGameView(game: game)
            } else if failed {
                ZStack {
                    FFColor.bg.ignoresSafeArea()
                    Text("Couldn't load this game.")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                }
            } else {
                ZStack {
                    FFColor.bg.ignoresSafeArea()
                    ProgressView().tint(FFColor.accent)
                }
            }
        }
        .task {
            game = await app.preseasonGame(gameID: gameID)
            failed = game == nil
        }
    }
}
