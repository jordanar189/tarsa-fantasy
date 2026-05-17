import SwiftUI

// Per-team profile sheet. Header with logo + record from schedule.
// Sub-tabs: Roster (grouped by position), Schedule (full season),
// Top performers (PPG leaders).
struct TeamProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let team: NFLTeamMeta
    @Binding var selectedPlayerID: String?

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case roster = "Roster"
        case schedule = "Schedule"
        case top = "Top performers"
        var id: String { rawValue }
    }

    @State private var section: Section = .roster
    @State private var schedules: [NFLGame] = []

    private var roster: [Player] {
        app.selectedPlayers().values
            .filter { $0.team == team.abbr }
            .sorted { positionWeight($0.position) < positionWeight($1.position) }
    }

    private var record: (w: Int, l: Int, t: Int) {
        var w = 0, l = 0, t = 0
        for g in schedules where g.status == .final {
            guard let h = g.homeScore, let a = g.awayScore else { continue }
            if g.home == team.abbr {
                if h > a { w += 1 } else if h < a { l += 1 } else { t += 1 }
            } else if g.away == team.abbr {
                if a > h { w += 1 } else if a < h { l += 1 } else { t += 1 }
            }
        }
        return (w, l, t)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.l) {
                        header
                        SegmentedTabPicker(items: Section.allCases, selection: $section) {
                            Text($0.rawValue)
                        }
                        switch section {
                        case .roster:   rosterSection
                        case .schedule: scheduleSection
                        case .top:      topPerformersSection
                        }
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(team.abbr)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(FFColor.accent)
                }
            }
            .task {
                let all = await app.schedules(season: app.selectedSeason)
                schedules = all.filter { $0.home == team.abbr || $0.away == team.abbr }
            }
        }
    }

    private var header: some View {
        let r = record
        return HStack(spacing: FFSpace.l) {
            TeamLogoCircle(url: team.logoURL, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(team.fullName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(FFColor.textPrimary)
                Text("\(team.conference) \(team.division)".uppercased())
                    .font(.ffMicro).tracking(0.8)
                    .foregroundStyle(FFColor.textTertiary)
                Text("\(r.w)–\(r.l)\(r.t > 0 ? "–\(r.t)" : "")")
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.accent)
            }
            Spacer()
        }
        .ffCard()
    }

    // MARK: - Roster

    private var rosterSection: some View {
        let grouped = Dictionary(grouping: roster, by: { $0.position.uppercased() })
        let order = ["QB", "RB", "WR", "TE", "K", "DEF"]
        let sortedKeys = grouped.keys.sorted { a, b in
            let ai = order.firstIndex(of: a) ?? Int.max
            let bi = order.firstIndex(of: b) ?? Int.max
            if ai != bi { return ai < bi }
            return a < b
        }
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            ForEach(sortedKeys, id: \.self) { pos in
                if let players = grouped[pos] {
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        Text(pos).ffEyebrow().padding(.leading, FFSpace.s)
                        VStack(spacing: 0) {
                            ForEach(players.sorted {
                                Fantasy.seasonTotals($0.games).points(scoring: .ppr) >
                                Fantasy.seasonTotals($1.games).points(scoring: .ppr)
                            }) { p in
                                Button { selectedPlayerID = p.id } label: { rosterRow(p) }
                                    .buttonStyle(.plain)
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
            if roster.isEmpty {
                Text("No players found for \(team.abbr) this season.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            }
        }
    }

    private func rosterRow(_ p: Player) -> some View {
        let summary = Fantasy.summary(p, scoring: .ppr)
        return HStack(spacing: FFSpace.m) {
            PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(p.name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    if let n = p.profile?.jerseyNumber {
                        Text("#\(n)").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                    }
                }
                HStack(spacing: 6) {
                    PositionPill(position: p.position)
                    Text("\(summary.gamesPlayed) GP")
                        .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
            Spacer()
            Sparkline(series: Fantasy.sparklineSeries(games: p.games, scoring: .ppr))
            VStack(alignment: .trailing, spacing: 2) {
                Text(summary.points.fpString).font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                Text("\(summary.pointsPerGame.fpString)/g")
                    .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("\(String(app.selectedSeason)) SCHEDULE").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                ForEach(schedules.sorted { $0.week < $1.week }) { g in
                    scheduleRow(g)
                }
                if schedules.isEmpty {
                    Text("No schedule loaded.")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                        .padding(FFSpace.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func scheduleRow(_ g: NFLGame) -> some View {
        let isHome = g.home == team.abbr
        let opp = isHome ? g.away : g.home
        let prefix = isHome ? "vs" : "@"
        let outcome: (String, Color)? = {
            guard g.status == .final, let h = g.homeScore, let a = g.awayScore else { return nil }
            let our = isHome ? h : a
            let theirs = isHome ? a : h
            if our > theirs { return ("W \(our)-\(theirs)", FFColor.positive) }
            if our < theirs { return ("L \(our)-\(theirs)", FFColor.negative) }
            return ("T \(our)-\(theirs)", FFColor.textSecondary)
        }()
        return HStack {
            Text("W\(g.week)")
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.textTertiary)
                .frame(width: 36, alignment: .leading)
            Text("\(prefix) \(opp)")
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
            Spacer()
            if let (text, color) = outcome {
                Text(text).font(.ffStatSmall).foregroundStyle(color)
            } else if let k = g.kickoff {
                Text(k.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    // MARK: - Top performers

    private var topPerformersSection: some View {
        let ranked = roster.sorted {
            Fantasy.seasonTotals($0.games).points(scoring: .ppr) >
            Fantasy.seasonTotals($1.games).points(scoring: .ppr)
        }.prefix(10)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("TOP 10 FANTASY PRODUCERS").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                ForEach(Array(ranked.enumerated()), id: \.element.id) { idx, p in
                    Button { selectedPlayerID = p.id } label: {
                        HStack(spacing: FFSpace.m) {
                            Text("\(idx + 1)")
                                .font(.ffStatSmall)
                                .foregroundStyle(idx < 3 ? FFColor.accent : FFColor.textTertiary)
                                .frame(width: 26, alignment: .leading)
                            PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                                HStack(spacing: 6) {
                                    PositionPill(position: p.position)
                                    Text("\(Fantasy.seasonTotals(p.games).gamesPlayed) GP")
                                        .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                                }
                            }
                            Spacer()
                            Text(Fantasy.summary(p, scoring: .ppr).points.fpString)
                                .font(.ffStatMedium)
                                .foregroundStyle(FFColor.textPrimary)
                        }
                        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                        .ffHairlineBottom()
                    }
                    .buttonStyle(.plain)
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

private func positionWeight(_ pos: String) -> Int {
    switch pos.uppercased() {
    case "QB": return 0
    case "RB": return 1
    case "WR": return 2
    case "TE": return 3
    case "K":  return 4
    case "DEF": return 5
    default:   return 6
    }
}
