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
        case overview = "Overview"   // at-a-glance season + acquire actions
        case details  = "Details"    // the full stat breakdown (formerly Overview)
        case career   = "Career"
        case gameLog  = "Game Log"
        case splits   = "Splits"
        case advanced = "Advanced"
        case matchups = "Matchups"
        case injuries = "Injuries"
        var id: String { rawValue }
    }

    @State private var scoring: Scoring = .ppr
    // Custom per-stat weights from the selected league, when it overrides the
    // preset. Threaded alongside `scoring` so every point figure on the page
    // reflects the league's actual scoring.
    @State private var scoringSettings: ScoringSettings? = nil
    @State private var section: Section = .overview
    @State private var schedules: [NFLGame] = []
    // Latest regular-season week with league-wide stats, cached so the game-log
    // back-fill doesn't rescan every player on each render. Refreshed in `.task`.
    @State private var maxRegWeek: Int = 0
    @State private var snapCounts: [String: [Int: SnapCount]] = [:]
    @State private var rankByID: [String: PositionRank] = [:]
    @State private var dvpByPosition: [String: [String: DvPEntry]] = [:]
    @State private var teamTargets: [String: [Int: Double]] = [:]
    @State private var teamTDs: [String: [Int: Double]] = [:]
    @State private var projection: PlayerProjection? = nil
    @State private var nicknameHistory: [NicknameHistoryEntry] = []
    @State private var warByID: [String: Double] = [:]
    @State private var careerSeasons: [Fantasy.CareerSeasonLine] = []
    @State private var careerLoading = false
    @State private var careerLoadedPlayerID: String? = nil
    @State private var careerLoadToken = 0
    @State private var breakdownGame: Game? = nil
    // Injury history (career-wide, season-independent). Loaded lazily the first
    // time the tab opens, mirroring the Career load pattern.
    @State private var injuryEvents: [InjuryEvent] = []
    @State private var injuryLoading = false
    @State private var injuryLoadedPlayerID: String? = nil
    @State private var injuryLoadToken = 0
    // Season-range filter; nil = all time (the default).
    @State private var injuryStartSeason: Int? = nil
    @State private var injuryEndSeason: Int? = nil
    // Acquisition (Overview tab): waiver/free-agent claim + trade entry for the
    // selected league. `dropped` distinguishes instant adds from waiver claims.
    @State private var dropped: [DroppedPlayer] = []
    @State private var claimTarget: AddClaimTarget? = nil
    @State private var tradeTarget: AcquireTradeTarget? = nil
    // Recent headlines tagging this player (Overview card).
    @State private var newsItems: [PlayerNewsItem] = []
    // Market context (Overview card): draft ADP and MFL add/drop percentages.
    @State private var adpByID: [String: Double] = [:]
    @State private var trendingByID: [String: TrendingPlayer] = [:]

    private var player: Player? { app.displaySelectedPlayers()[playerID] }
    private var isProjected: Bool { app.isProjectedSeason(app.selectedSeason) }

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
                            valueCard(for: player)
                            sectionPicker
                            switch section {
                            case .overview: overviewSection(for: player)
                            case .details:  detailsSection(for: player)
                            case .career:   careerSection(for: player)
                            case .gameLog:  gameLogSection(for: player)
                            case .splits:   splitsSection(for: player)
                            case .advanced: advancedSection(for: player)
                            case .matchups: matchupsSection(for: player)
                            case .injuries: injurySection()
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // This screen is itself a sheet — host the team profile locally
            // so the header's team abbreviation can link out.
            .hostsTeamProfileSheet()
            .navigationTitle(player?.name ?? "Player")
            .navigationBarTitleDisplayMode(.inline)
            .leagueSwitcher()
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
            // Keyed on season too: switching leagues changes app.selectedSeason
            // while this view stays mounted, and every load below is season-
            // scoped — re-run so schedules/snaps/ranks don't go stale.
            .task(id: "\(playerID)#\(app.selectedSeason)") {
                // Stats inherit the selected league's scoring (preset + any
                // custom per-stat weights).
                scoring = app.activeScoring
                scoringSettings = app.activeScoringSettings
                careerSeasons = []
                careerLoadedPlayerID = nil
                await app.ensureProjectedSnapshot(season: app.selectedSeason)
                schedules = await app.schedules(season: app.selectedSeason)
                maxRegWeek = app.availableWeeks(season: app.selectedSeason).max() ?? 0
                snapCounts = await app.snapCounts(season: app.selectedSeason)
                rankByID = Fantasy.positionRanks(
                    players: app.displaySelectedPlayers(), scoring: scoring, settings: scoringSettings
                )
                let players = app.displaySelectedPlayers()
                teamTargets = Fantasy.teamTargetsPerWeek(players: players)
                teamTDs     = Fantasy.teamTouchdownsPerWeek(players: players)
                warByID = Fantasy.warByPlayer(
                    players: players, scoring: scoring,
                    settings: scoringSettings,
                    config: app.selectedLeague?.rosterConfig ?? .default,
                    teamCount: app.selectedLeague?.teams.count ?? 12
                )
                // Load DvP for the player's own position only — that's the
                // only matchup we render.
                if let pos = player?.position.uppercased() {
                    let table = await app.dvp(season: app.selectedSeason, position: pos)
                    dvpByPosition[pos] = table
                }
                projection = await app.liveProjection(
                    playerID: playerID, season: app.selectedSeason, scoring: scoring
                )
                nicknameHistory = await app.playerNicknameHistory(playerID: playerID)
                newsItems = await app.news(playerID: playerID, limit: 5)
                adpByID = await app.adp(season: app.selectedSeason, scoring: scoring)
                trendingByID = Dictionary(
                    uniqueKeysWithValues: await app.trendingPlayers(for: app.selectedLeague)
                        .map { ($0.playerID, $0) }
                )
                if section == .career, let player {
                    await loadCareer(for: player)
                }
                if section == .injuries, injuryLoadedPlayerID != player?.id, let player {
                    await loadInjuries(for: player)
                }
            }
            .onChange(of: section) { _, new in
                if new == .career, careerLoadedPlayerID != playerID, let player {
                    Task { await loadCareer(for: player) }
                }
                if new == .injuries, injuryLoadedPlayerID != playerID, let player {
                    Task { await loadInjuries(for: player) }
                }
            }
            .onChange(of: app.activeScoring) { _, new in scoring = new }
            .onChange(of: app.activeScoringSettings) { _, new in scoringSettings = new }
            .onChange(of: scoring) { _, _ in applyScoringChange() }
            .onChange(of: scoringSettings) { _, _ in applyScoringChange() }
            .sheet(item: $breakdownGame) { g in
                ScoreBreakdownSheet(
                    playerName: player?.name ?? "Player",
                    game: g,
                    scoring: scoring,
                    settings: scoringSettings
                )
            }
            .sheet(item: $claimTarget) { ctx in
                if let lg = app.selectedLeague {
                    WaiverClaimSheet(
                        league: lg, team: ctx.team,
                        addPlayer: ctx.addPlayer,
                        isOnWaivers: ctx.isOnWaivers,
                        waiverUntil: ctx.waiverUntil
                    ) { updated in
                        if let updated { app.selectedLeague = updated }
                        Task { await reloadDropped() }
                    }
                }
            }
            .sheet(item: $tradeTarget) { t in
                if let lg = app.selectedLeague {
                    ProposeTradeView(
                        league: lg, fromTeam: t.fromTeam, counterOf: nil,
                        requestPlayer: (teamID: t.toTeamID, playerID: t.playerID)
                    ) { _ in }
                }
            }
            .task(id: app.selectedLeagueID) { await reloadDropped() }
        }
    }

    private func loadCareer(for p: Player) async {
        careerLoadToken &+= 1
        let token = careerLoadToken
        careerLoading = true
        let result = await app.careerSeasons(playerID: p.id, scoring: scoring, settings: scoringSettings)
        // Ignore a result a newer request (scoring/section change) superseded —
        // otherwise a slow PPR load could overwrite a fresher Standard one.
        guard token == careerLoadToken else { return }
        careerSeasons = result
        careerLoadedPlayerID = p.id
        careerLoading = false
    }

    private func loadInjuries(for p: Player) async {
        injuryLoadToken &+= 1
        let token = injuryLoadToken
        injuryLoading = true
        // Clear stale data up front so a player switch never renders the
        // previous player's injuries during the fetch window — with no events
        // the section falls back to its loading state.
        injuryEvents = []
        // Reset to the default all-time view whenever a new player loads.
        injuryStartSeason = nil
        injuryEndSeason = nil
        let result = await app.injuryHistory(playerID: p.id)
        guard token == injuryLoadToken else { return }
        injuryEvents = result
        injuryLoadedPlayerID = p.id
        injuryLoading = false
    }

    // Recompute the scoring-dependent derived state after the active scoring
    // (preset or custom weights) changes — e.g. when the user switches leagues.
    private func applyScoringChange() {
        let players = app.displaySelectedPlayers()
        rankByID = Fantasy.positionRanks(players: players, scoring: scoring, settings: scoringSettings)
        warByID = Fantasy.warByPlayer(
            players: players, scoring: scoring,
            settings: scoringSettings,
            config: app.selectedLeague?.rosterConfig ?? .default,
            teamCount: app.selectedLeague?.teams.count ?? 12
        )
        Task {
            projection = await app.liveProjection(
                playerID: playerID, season: app.selectedSeason, scoring: scoring
            )
        }
        if careerLoadedPlayerID == playerID {
            if section == .career, let player {
                Task { await loadCareer(for: player) }
            } else {
                // Loaded under the old scoring; drop it so the tab reloads with
                // the new scoring when next opened.
                careerLoadedPlayerID = nil
            }
        }
    }

    // MARK: - Header

    private func header(_ p: Player) -> some View {
        let nonActiveStatus: String? = {
            guard let s = p.profile?.status, !s.isEmpty, s.uppercased() != "ACT" else { return nil }
            return s
        }()
        return VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack(alignment: .top, spacing: FFSpace.l) {
                PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(FFColor.textPrimary)
                    HStack(spacing: 6) {
                        PositionPill(position: p.position)
                        Text(p.team).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                            .teamLink(p.team)
                        if let n = p.profile?.jerseyNumber {
                            Text("· #\(n)").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        }
                        if let nonActiveStatus {
                            StateChip(state: .locked, label: nonActiveStatus)
                        }
                        if let value = app.playerValue(playerID: p.id) {
                            PlayerValueBadge(value: value)
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
        .ffHeroCard()
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
            if let projection, !isProjected {
                heroStat(
                    label: "PROJ",
                    value: String(format: "%.1f", projection.points),
                    color: FFColor.accent
                )
            }
            if let rank = rankByID[p.id] {
                heroStat(label: "RANK", value: rank.label, color: FFColor.accent)
            }
            if let war = warByID[p.id] {
                heroStat(label: "WAR", value: String(format: "%+.1f", war),
                         color: war >= 0 ? FFColor.accent : FFColor.negative)
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
        switch Fantasy.trendDirection(games: games, scoring: scoring, settings: scoringSettings) {
        case .up:   return "↑ Rising"
        case .flat: return "→ Steady"
        case .down: return "↓ Cooling"
        }
    }
    private func trendColor(games: [Game]) -> Color {
        switch Fantasy.trendDirection(games: games, scoring: scoring, settings: scoringSettings) {
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

    // MARK: - Value (high/medium/low) — owner-set, league-visible

    // The team in the selected league that currently rosters this player,
    // if any. Nil for free agents or when no league is selected.
    private func owningTeam(for p: Player) -> FantasyTeam? {
        guard let lg = app.selectedLeague else { return nil }
        return lg.teams.first { $0.roster.contains(p.id) }
    }

    private func canEditValue(for p: Player) -> Bool {
        guard let owner = owningTeam(for: p) else { return false }
        return owner.id == myLeagueTeam?.id
    }

    @ViewBuilder
    private func valueCard(for p: Player) -> some View {
        let owner = owningTeam(for: p)
        let editable = canEditValue(for: p)
        if editable, let team = owner {
            ownerValueCard(player: p, team: team)
        } else if let owner, let value = app.playerValue(teamID: owner.id, playerID: p.id) {
            spectatorValueCard(owner: owner, value: value)
        }
    }

    private func ownerValueCard(player p: Player, team: FantasyTeam) -> some View {
        let current = app.playerValue(teamID: team.id, playerID: p.id)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("MY VALUE").ffEyebrow()
                Spacer()
                if current != nil {
                    Button {
                        Task { await applyValue(nil, for: p, team: team) }
                    } label: {
                        Text("Clear")
                            .font(.ffMicro.bold())
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                ForEach(PlayerValue.allCases) { v in
                    let selected = current == v
                    Button {
                        Task { await applyValue(selected ? nil : v, for: p, team: team) }
                    } label: {
                        Text(v.label)
                            .font(.ffCaption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selected ? valueColor(v).opacity(0.22) : FFColor.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: FFRadius.s)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: FFRadius.s)
                                    .strokeBorder(
                                        selected ? valueColor(v).opacity(0.6) : FFColor.border,
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(selected ? valueColor(v) : FFColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .ffCard()
    }

    private func spectatorValueCard(owner: FantasyTeam, value: PlayerValue) -> some View {
        HStack(spacing: FFSpace.s) {
            Text("\(owner.name.uppercased()) VALUES")
                .ffEyebrow()
            PlayerValueBadge(value: value)
            Spacer()
        }
        .ffCard()
    }

    private func valueColor(_ v: PlayerValue) -> Color {
        switch v {
        case .high:   return FFColor.positive
        case .medium: return FFColor.warning
        case .low:    return FFColor.negative
        }
    }

    private func applyValue(_ v: PlayerValue?, for p: Player, team: FantasyTeam) async {
        guard let lg = app.selectedLeague else { return }
        // On failure the picker snaps back to server state via the cache
        // refresh inside setPlayerValue; surfacing inline isn't worth the
        // wiring for what's essentially a one-tap rating control.
        try? await app.setPlayerValue(
            leagueID: lg.id, teamID: team.id, playerID: p.id, value: v
        )
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

    // MARK: - Overview (at-a-glance + acquire actions)

    private func overviewSection(for p: Player) -> some View {
        let games = p.games
        let total = Fantasy.seasonTotals(games).points(scoring: scoring, settings: scoringSettings)
        let gp = games.count
        let ppg = gp > 0 ? total / Double(gp) : 0
        let weekly = games.map { $0.points(scoring: scoring, settings: scoringSettings) }
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            if let acq = acquisition(for: p) {
                acquisitionCard(acq, player: p)
            }
            glanceCard(
                total: total, ppg: ppg, gp: gp,
                best: weekly.max() ?? 0, worst: weekly.min() ?? 0,
                trend: Fantasy.trendDirection(games: games, scoring: scoring, settings: scoringSettings)
            )
            marketCard(for: p)
            if !games.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("WEEKLY POINTS").ffEyebrow().padding(.leading, FFSpace.s)
                    WeeklyTrendChart(games: games, scoring: scoring, settings: scoringSettings)
                        .padding(FFSpace.m)
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.border, lineWidth: 1)
                        )
                }
            }
            if !newsItems.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("NEWS").ffEyebrow().padding(.leading, FFSpace.s)
                    ForEach(newsItems.prefix(3)) { item in
                        NewsCard(item: item, compact: true)
                    }
                }
            }
        }
    }

    // ADP · add/drop market movement · next-4-games schedule strength.
    // All three are optional data sources — the card renders whatever is
    // available and disappears entirely when none are.
    @ViewBuilder
    private func marketCard(for p: Player) -> some View {
        let adp = adpByID[p.id]
        let trend = trendingByID[p.id]
        let sos = upcomingSOS(for: p)
        if adp != nil || trend != nil || sos != nil {
            HStack(spacing: FFSpace.l) {
                if let adp {
                    marketColumn("ADP", String(format: "%.1f", adp), FFColor.textPrimary)
                }
                if let trend {
                    let rising = trend.adds >= trend.drops
                    marketColumn(
                        rising ? "ADDS 24H" : "DROPS 24H",
                        String(format: "%.0f%%", rising ? trend.adds : trend.drops),
                        rising ? FFColor.positive : FFColor.negative
                    )
                }
                if let sos {
                    marketColumn("NEXT \(sos.games)", sos.label, sos.color)
                }
                Spacer()
            }
            .ffCard()
        }
    }

    private func marketColumn(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value).font(.ffStatMedium).foregroundStyle(color)
        }
    }

    // Average DvP rank of the next few opponents at this player's position.
    // Rank 1 = allows the most fantasy points, so LOW average = soft slate.
    private func upcomingSOS(for p: Player) -> (label: String, color: Color, games: Int)? {
        guard !p.team.isEmpty else { return nil }
        let dvp = dvpByPosition[p.position.uppercased()] ?? [:]
        guard !dvp.isEmpty else { return nil }
        let now = Date()
        let upcoming = schedules
            .filter { g in (g.home == p.team || g.away == p.team) && (g.kickoff.map { $0 > now } ?? false) }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
            .prefix(4)
        let ranks = upcoming.compactMap { g -> Int? in
            let opp = g.home == p.team ? g.away : g.home
            return dvp[opp]?.rank
        }
        guard !ranks.isEmpty else { return nil }
        let avg = Double(ranks.reduce(0, +)) / Double(ranks.count)
        let label: String
        let color: Color
        switch avg {
        case ..<12:  label = "Soft";  color = FFColor.positive
        case ..<21:  label = "Even";  color = FFColor.warning
        default:     label = "Tough"; color = FFColor.negative
        }
        return (label, color, ranks.count)
    }

    private func acquisitionCard(_ acq: PlayerAcquisition, player p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(acquisitionEyebrow(acq)).ffEyebrow()
            AcquisitionButton(acquisition: acq, enabled: myLeagueTeam != nil) {
                handleAcquisition(acq, player: p)
            }
        }
        .ffCard()
    }

    private func glanceCard(total: Double, ppg: Double, gp: Int,
                            best: Double, worst: Double, trend: Trend) -> some View {
        VStack(spacing: FFSpace.m) {
            HStack(spacing: FFSpace.m) {
                glanceStat("PTS", total.fpString)
                glanceStat("PPG", ppg.fpString)
                glanceStat("GP", "\(gp)")
            }
            HStack(spacing: FFSpace.m) {
                glanceStat("BEST", best.fpString)
                glanceStat("WORST", worst.fpString)
                glanceStat("TREND", trendGlyph(trend), color: trendTint(trend))
            }
        }
        .ffCard()
    }

    private func glanceStat(_ label: String, _ value: String, color: Color = FFColor.textPrimary) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.ffStatMedium).foregroundStyle(color)
            Text(label).ffEyebrow(color: FFColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func trendGlyph(_ t: Trend) -> String {
        switch t { case .up: return "↑"; case .flat: return "→"; case .down: return "↓" }
    }
    private func trendTint(_ t: Trend) -> Color {
        switch t {
        case .up:   return FFColor.positive
        case .flat: return FFColor.textTertiary
        case .down: return FFColor.negative
        }
    }

    private func acquisitionEyebrow(_ acq: PlayerAcquisition) -> String {
        switch acq {
        case .addable:           return "FREE AGENT"
        case .claimable:         return "ON WAIVERS"
        case .trade(_, let name): return "ROSTERED BY \(name.uppercased())"
        case .onMyRoster:        return "ON YOUR ROSTER"
        case .unavailable:       return "AVAILABILITY"
        }
    }

    // The team the signed-in user controls in the selected league.
    private var myLeagueTeam: FantasyTeam? {
        guard let lg = app.selectedLeague else { return nil }
        if lg.isTest, let id = AppState.primaryTeamID(in: lg) {
            return lg.teams.first(where: { $0.id == id })
        }
        guard let uid = app.session?.userID else { return nil }
        return lg.teams.first(where: { $0.ownerID == uid })
    }

    private func acquisition(for p: Player) -> PlayerAcquisition? {
        guard let lg = app.selectedLeague else { return nil }
        let droppedByID = Dictionary(dropped.map { ($0.playerID, $0) }, uniquingKeysWith: { a, _ in a })
        let week = Fantasy.currentWeek(players: app.displaySelectedPlayers())
        return PlayerAcquisition.resolve(
            playerID: p.id, league: lg, myTeam: myLeagueTeam,
            players: app.displaySelectedPlayers(),
            droppedByID: droppedByID, week: week
        )
    }

    private func handleAcquisition(_ acq: PlayerAcquisition, player p: Player) {
        guard let team = myLeagueTeam else { return }
        let summary = Fantasy.summary(p, scoring: scoring)
        switch acq {
        case .addable:
            claimTarget = AddClaimTarget(team: team, addPlayer: summary, isOnWaivers: false, waiverUntil: nil)
        case .claimable(let until):
            claimTarget = AddClaimTarget(team: team, addPlayer: summary, isOnWaivers: true, waiverUntil: until)
        case .trade(let teamID, _):
            tradeTarget = AcquireTradeTarget(fromTeam: team, toTeamID: teamID, playerID: p.id)
        case .onMyRoster, .unavailable:
            break
        }
    }

    private func reloadDropped() async {
        guard let id = app.selectedLeagueID else { dropped = []; return }
        dropped = await app.droppedPlayers(leagueID: id)
    }

    // MARK: - Details (full stat breakdown)

    private func detailsSection(for p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.l) {
            totalsCard(for: p)
            if warByID[p.id] != nil { warCard(for: p) }
            if let card = ranksCard(for: p) { card }
            if !nicknameHistory.isEmpty { nicknameHistoryCard }
            if !p.games.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("WEEKLY POINTS").ffEyebrow().padding(.leading, FFSpace.s)
                    WeeklyTrendChart(games: p.games, scoring: scoring, settings: scoringSettings)
                        .padding(FFSpace.m)
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.border, lineWidth: 1)
                        )
                }
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("WEEKLY DISTRIBUTION").ffEyebrow().padding(.leading, FFSpace.s)
                    PositionDistributionChart(games: p.games, scoring: scoring, settings: scoringSettings)
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

    // Every nickname this player has been given by a fantasy team, active or
    // archived (dropped). Active ones are tinted; archived show when they were
    // retired so the history reads as a timeline.
    private var nicknameHistoryCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("NICKNAMES").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                ForEach(nicknameHistory) { entry in
                    HStack(spacing: FFSpace.m) {
                        Image(systemName: entry.isActive ? "quote.bubble.fill" : "quote.bubble")
                            .font(.system(size: 15))
                            .foregroundStyle(entry.isActive ? FFColor.accent : FFColor.textTertiary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(entry.nickname)”")
                                .font(.ffBody)
                                .foregroundStyle(entry.isActive ? FFColor.textPrimary : FFColor.textSecondary)
                                .lineLimit(1)
                            Text("\(entry.teamName) · \(entry.leagueName)")
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if entry.isActive {
                            Text("ACTIVE").ffEyebrow(color: FFColor.accent)
                        } else if let cleared = entry.clearedAt {
                            Text("Dropped \(cleared.formatted(.dateTime.month(.abbreviated).day()))")
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
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

    // Wins Above Replacement: regular-season wins this player added over a
    // freely-available replacement starter at his position, given the league's
    // scoring and roster. Negative means a replacement would have done better.
    private func warCard(for p: Player) -> some View {
        let war = warByID[p.id] ?? 0
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(isProjected ? "PROJECTED WAR" : "WINS ABOVE REPLACEMENT")
                .ffEyebrow().padding(.leading, FFSpace.s)
            HStack(alignment: .firstTextBaseline, spacing: FFSpace.m) {
                Text(String(format: "%+.1f", war))
                    .font(.ffStatLarge)
                    .foregroundStyle(war >= 0 ? FFColor.accent : FFColor.negative)
                Text("\(isProjected ? "Projected " : "")regular-season wins added vs a replaceable \(p.position.uppercased()) starter.")
                    .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(FFSpace.m)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func totalsCard(for p: Player) -> some View {
        let t = Fantasy.seasonTotals(p.games)
        let pts = t.points(scoring: scoring, settings: scoringSettings)
        let gp = max(t.gamesPlayed, 1)
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isProjected ? "PROJECTED" : "SEASON").ffEyebrow(color: isProjected ? FFColor.accent : FFColor.textTertiary)
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
            if isProjected {
                Text("Projected over \(t.gamesPlayed) scheduled games · box-score detail begins Week 1")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            } else {
                statsGrid(t)
            }
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
        let sorted = p.games.sorted { $0.points(scoring: scoring, settings: scoringSettings) > $1.points(scoring: scoring, settings: scoringSettings) }
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
            Text(game.points(scoring: scoring, settings: scoringSettings).fpString)
                .font(.ffStatMedium)
                .foregroundStyle(color)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    // MARK: - Game Log

    private func gameLogSection(for p: Player) -> some View {
        let games = gameLogRows(for: p)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(isProjected ? "PROJECTED GAME LOG" : "GAME LOG").ffEyebrow().padding(.leading, FFSpace.s)
            if games.isEmpty {
                Text("No games played yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            } else {
                VStack(spacing: 0) {
                    ForEach(games) { g in
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

    // Game log rows, deduped to one per week and back-filled with 0-stat
    // entries for every week the player's current team has already played but
    // the player recorded nothing (DNP, inactive, healthy scratch). A bye week
    // produces no schedule row, so it's naturally skipped. Display-only — the
    // synthesized zeros never feed scoring, splits averages, or career totals.
    private func gameLogRows(for p: Player) -> [Game] {
        var byWeek: [Int: Game] = [:]
        for g in p.games {
            // Defensive de-dup: if two rows ever share a week, keep the one
            // with real production over an empty stub.
            if let existing = byWeek[g.week], existing.points(scoring: .ppr) >= g.points(scoring: .ppr) {
                continue
            }
            byWeek[g.week] = g
        }
        // player_games is regular-season only, so the latest week with any
        // stats across the league marks the REG boundary (cached in maxRegWeek).
        // Capping fills there keeps postseason schedule rows (weeks 19+) out of
        // the log and avoids inventing zeros for weeks that haven't been played.
        if !p.team.isEmpty && maxRegWeek > 0 {
            for sched in schedules {
                // `schedules` can briefly lag a season switch (it reloads in
                // .task); skip rows from any other season so we never synthesize
                // weeks/opponents from the previously selected season.
                guard sched.season == app.selectedSeason else { continue }
                guard sched.status == .final || sched.status == .inProgress else { continue }
                guard sched.week <= maxRegWeek else { continue }
                guard sched.home == p.team || sched.away == p.team, byWeek[sched.week] == nil else { continue }
                var stub = Game()
                stub.season = sched.season
                stub.week = sched.week
                stub.team = p.team
                stub.opponent = sched.opponent(of: p.team) ?? ""
                byWeek[sched.week] = stub
            }
        }
        return byWeek.values.sorted { $0.week < $1.week }
    }

    private func gameRow(_ g: Game, snap: SnapCount?) -> some View {
        let pts = g.points(scoring: scoring, settings: scoringSettings)
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
            Button {
                breakdownGame = g
            } label: {
                HStack(spacing: 3) {
                    Text(pts.fpString)
                        .font(.ffStatMedium)
                        .foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .frame(minWidth: 56, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        let total = games.reduce(0.0) { $0 + $1.points(scoring: scoring, settings: scoringSettings) }
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

    @ViewBuilder
    private func advancedSection(for p: Player) -> some View {
        if isProjected {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("ADVANCED").ffEyebrow().padding(.leading, FFSpace.s)
                Text("Usage projections (snaps, target share, etc.) aren't available in the preseason. They'll populate once the season kicks off.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.m)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )
            }
        } else {
            advancedSectionReal(for: p)
        }
    }

    private func advancedSectionReal(for p: Player) -> some View {
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
                let avg = games.reduce(0.0) { $0 + $1.points(scoring: scoring, settings: scoringSettings) } / Double(games.count)
                let best = games.map { $0.points(scoring: scoring, settings: scoringSettings) }.max() ?? 0
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

    // MARK: - Injuries (history tracker)

    @ViewBuilder
    private func injurySection() -> some View {
        if injuryLoading && injuryEvents.isEmpty {
            injuryMessageCard {
                HStack(spacing: FFSpace.s) {
                    ProgressView().tint(FFColor.accent)
                    Text("Loading injury history…")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                }
            }
        } else if injuryEvents.isEmpty {
            injuryMessageCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No injury history on record.")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    Text("We track reported injuries from recent seasons — a clean record here means none were reported.")
                        .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
        } else {
            injuryContent()
        }
    }

    private func injuryContent() -> some View {
        let allSeasons = injuryEvents.map(\.season)
        let minS = allSeasons.min() ?? 0
        let maxS = allSeasons.max() ?? 0
        let start = injuryStartSeason ?? minS
        let end = injuryEndSeason ?? maxS
        let filtered = injuryEvents.filter { $0.season >= start && $0.season <= end }
        let stats = Fantasy.injuryRegionStats(from: filtered)
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            if minS != maxS {
                injurySeasonFilter(minSeason: minS, maxSeason: maxS, start: start, end: end)
            }
            injurySummaryCard(events: filtered, start: start, end: end)
            injuryHeatCard(stats: stats)
            injuryListSection(events: filtered)
        }
    }

    private func injurySeasonFilter(minSeason: Int, maxSeason: Int, start: Int, end: Int) -> some View {
        let years = Array(minSeason...maxSeason)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("SEASON RANGE").ffEyebrow().padding(.leading, FFSpace.s)
            HStack(spacing: FFSpace.s) {
                Menu {
                    ForEach(years.filter { $0 <= end }, id: \.self) { yr in
                        Button(String(yr)) { injuryStartSeason = yr }
                    }
                } label: {
                    injuryFilterChip(label: "From", value: String(start))
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
                Menu {
                    ForEach(years.filter { $0 >= start }, id: \.self) { yr in
                        Button(String(yr)) { injuryEndSeason = yr }
                    }
                } label: {
                    injuryFilterChip(label: "To", value: String(end))
                }
                Spacer()
                if injuryStartSeason != nil || injuryEndSeason != nil {
                    Button {
                        injuryStartSeason = nil
                        injuryEndSeason = nil
                    } label: {
                        Text("All time")
                            .font(.ffCaption.bold())
                            .foregroundStyle(FFColor.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(FFSpace.m)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func injuryFilterChip(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            Text(value)
                .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
        .background(FFColor.surfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(FFColor.border, lineWidth: 1))
    }

    private func injurySummaryCard(events: [InjuryEvent], start: Int, end: Int) -> some View {
        let total = events.count
        let byGroup = Dictionary(grouping: events.compactMap { $0.group }, by: { $0 })
        let topGroup = byGroup.max { $0.value.count < $1.value.count }
        let rangeLabel = start == end ? String(start) : "\(start)–\(end)"
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("INJURIES").ffEyebrow(color: FFColor.accent)
                    Text("\(total)")
                        .font(.ffStatLarge)
                        .foregroundStyle(FFColor.textPrimary)
                    Text("\(total == 1 ? "reported injury" : "reported injuries") · \(rangeLabel)")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                if let topGroup {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("MOST AFFECTED").ffEyebrow(color: FFColor.textTertiary)
                        Text(topGroup.key.displayName)
                            .font(.ffStatMedium)
                            .foregroundStyle(FFColor.negative)
                        Text("\(topGroup.value.count)×")
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func injuryHeatCard(stats: [BodyRegion: Fantasy.RegionStat]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("INJURY MAP").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: FFSpace.l) {
                if stats.isEmpty {
                    Text("No localized injuries in this range.")
                        .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, FFSpace.l)
                } else {
                    BodyHeatMap(stats: stats)
                    BodyHeatLegend()
                    Text("Color shows worst severity; the number counts injuries at that area. Sides aren't recorded, so paired areas show on both.")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(FFSpace.l)
            .frame(maxWidth: .infinity)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func injuryListSection(events: [InjuryEvent]) -> some View {
        // events are already newest-first; pull distinct seasons in that order.
        var seen = Set<Int>()
        let seasons = events.map(\.season).filter { seen.insert($0).inserted }
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            Text("INJURY LOG").ffEyebrow().padding(.leading, FFSpace.s)
            ForEach(seasons, id: \.self) { season in
                let rows = events.filter { $0.season == season }
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text(String(season))
                        .font(.ffStatMedium)
                        .foregroundStyle(FFColor.textPrimary)
                        .padding(.leading, FFSpace.s)
                    VStack(spacing: 0) {
                        ForEach(rows) { injuryRow($0) }
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

    private func injuryRow(_ e: InjuryEvent) -> some View {
        HStack(alignment: .top, spacing: FFSpace.m) {
            Circle()
                .fill(injuryStatusColor(e.worstStatus))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.rawDetail)
                    .font(.ffBody.weight(.semibold))
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1)
                Text(injuryWeekLabel(e))
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
            Spacer(minLength: FFSpace.s)
            injuryStatusBadge(e.worstStatus)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    private func injuryWeekLabel(_ e: InjuryEvent) -> String {
        if e.startWeek == 0 && e.endWeek == 0 { return "Preseason report" }
        if e.startWeek == e.endWeek { return "Week \(e.startWeek)" }
        return "Weeks \(e.startWeek)–\(e.endWeek) · \(e.weeksOut) wks"
    }

    private func injuryStatusColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "OUT", "IR", "INJURED RESERVE", "PUP", "SUSPENDED", "SUS", "NFI":
            return FFColor.negative
        case "DOUBTFUL", "QUESTIONABLE":
            return FFColor.warning
        default:
            return FFColor.textSecondary
        }
    }

    private func injuryStatusBadge(_ status: String) -> some View {
        let color = injuryStatusColor(status)
        let label = status.isEmpty ? "—" : status.uppercased()
        return Text(label)
            .font(.ffMicro.bold())
            .tracking(0.6)
            .lineLimit(1)
            .padding(.horizontal, FFSpace.s).padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func injuryMessageCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(FFSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }

    // MARK: - Career (multi-season history)

    // Year-by-year breakdown across every season we have data for: a career
    // aggregate up top, then a card per season with that year's fantasy
    // position rank and position-relevant counting stats. Loaded lazily the
    // first time the tab is opened (it touches every season's snapshot).
    @ViewBuilder
    private func careerSection(for p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.l) {
            if careerLoading && careerSeasons.isEmpty {
                careerMessageCard {
                    HStack(spacing: FFSpace.s) {
                        ProgressView().tint(FFColor.accent)
                        Text("Loading career…")
                            .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    }
                }
            } else if careerSeasons.isEmpty {
                careerMessageCard {
                    Text("No career stats available.")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                }
            } else {
                careerSummaryCard(for: p)
                Text("BY SEASON").ffEyebrow().padding(.leading, FFSpace.s)
                ForEach(careerSeasons) { line in
                    careerSeasonCard(line)
                }
            }
        }
    }

    private func careerMessageCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(FFSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }

    private func careerSummaryCard(for p: Player) -> some View {
        let totalGP  = careerSeasons.reduce(0) { $0 + $1.gamesPlayed }
        let agg = Fantasy.combinedTotals(careerSeasons.map(\.totals))
        // Derive from the exact aggregate, not the per-season rounded points,
        // so the header matches the stat grid over a long career.
        let totalPts = Fantasy.round2(agg.points(scoring: scoring, settings: scoringSettings))
        let ppg = totalGP > 0 ? Fantasy.round2(totalPts / Double(totalGP)) : 0
        let bestLine = careerSeasons
            .filter { $0.positionRank != nil }
            .min { $0.positionRank!.rank < $1.positionRank!.rank }
        let stats = careerStatLine(position: p.position, totals: agg)
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CAREER").ffEyebrow(color: FFColor.accent)
                    Text(totalPts.fpString)
                        .font(.ffStatLarge)
                        .foregroundStyle(FFColor.textPrimary)
                    Text("\(careerSeasons.count) seasons · \(totalGP) games · \(ppg.fpString)/g")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                if let bestLine, let rank = bestLine.positionRank {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("BEST FINISH").ffEyebrow(color: FFColor.textTertiary)
                        Text(rank.label)
                            .font(.ffStatMedium)
                            .foregroundStyle(FFColor.accent)
                        Text(String(bestLine.season))
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
            if !stats.isEmpty {
                Rectangle().fill(FFColor.border).frame(height: 1)
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: FFSpace.m) {
                    ForEach(stats, id: \.0) { s in stat(s.0, s.1) }
                }
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func careerSeasonCard(_ line: Fantasy.CareerSeasonLine) -> some View {
        let stats = careerStatLine(position: line.position, totals: line.totals)
        return VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack(alignment: .firstTextBaseline, spacing: FFSpace.s) {
                Text(String(line.season))
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.textPrimary)
                Text(line.teamLabel)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
                Spacer()
                if let rank = line.positionRank { careerRankPill(rank) }
            }
            if !stats.isEmpty {
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: FFSpace.s) {
                    ForEach(stats, id: \.0) { s in stat(s.0, s.1) }
                }
            }
            Rectangle().fill(FFColor.border).frame(height: 1)
            HStack(spacing: FFSpace.l) {
                stat("PTS", line.points.fpString)
                stat("PPG", line.pointsPerGame.fpString)
                stat("GP", "\(line.gamesPlayed)")
                Spacer()
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func careerRankPill(_ rank: PositionRank) -> some View {
        let color = careerRankColor(rank.rank)
        return HStack(spacing: 4) {
            Text(rank.label)
                .font(.ffCaption.bold())
                .padding(.horizontal, FFSpace.s).padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
            Text("of \(rank.totalAtPosition)")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
        }
    }

    private func careerRankColor(_ r: Int) -> Color {
        switch r {
        case ...5:  return FFColor.positive
        case ...12: return FFColor.accent
        case ...24: return FFColor.warning
        default:    return FFColor.textSecondary
        }
    }

    // Position-relevant counting totals for a career row. K (and anything we
    // don't carry box-score stats for) shows points only.
    private func careerStatLine(position: String, totals t: SeasonTotals) -> [(String, String)] {
        switch position.uppercased() {
        case "QB":
            return [
                ("PASS YD", t.passingYards.statString),
                ("PASS TD", t.passingTDs.statString),
                ("INT",     t.passingInterceptions.statString),
                ("RUSH YD", t.rushingYards.statString),
                ("RUSH TD", t.rushingTDs.statString),
                ("CMP",     t.completions.statString),
            ]
        case "RB":
            return [
                ("RUSH YD", t.rushingYards.statString),
                ("RUSH TD", t.rushingTDs.statString),
                ("CAR",     t.carries.statString),
                ("REC",     t.receptions.statString),
                ("REC YD",  t.receivingYards.statString),
                ("REC TD",  t.receivingTDs.statString),
            ]
        case "WR", "TE":
            return [
                ("REC",     t.receptions.statString),
                ("TGT",     t.targets.statString),
                ("REC YD",  t.receivingYards.statString),
                ("REC TD",  t.receivingTDs.statString),
            ] + (t.carries > 0 ? [
                ("RUSH YD", t.rushingYards.statString),
                ("RUSH TD", t.rushingTDs.statString),
            ] : [])
        default:
            return []
        }
    }
}

// MARK: - Score breakdown sheet

// Tapping a score in the game log opens this: a line-by-line accounting of how
// each box-score stat contributed to that week's fantasy points, under the
// scoring the game log is showing.
private struct ScoreBreakdownSheet: View {
    let playerName: String
    let game: Game
    let scoring: Scoring
    // Computed once at init — the inputs are immutable for the sheet's lifetime,
    // so there's no need to recompute on every layout pass.
    private let breakdown: (components: [Fantasy.ScoreComponent], total: Double)
    @Environment(\.dismiss) private var dismiss

    init(playerName: String, game: Game, scoring: Scoring, settings: ScoringSettings?) {
        self.playerName = playerName
        self.game = game
        self.scoring = scoring
        self.breakdown = Fantasy.scoreBreakdown(game: game, scoring: scoring, settings: settings)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: FFSpace.l) {
                        headerCard(total: breakdown.total)
                        if breakdown.components.isEmpty {
                            emptyCard
                        } else {
                            componentsCard(breakdown.components, total: breakdown.total)
                        }
                    }
                    .padding(FFSpace.l)
                }
            }
            .navigationTitle("Scoring Breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func headerCard(total: Double) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(playerName.uppercased()).ffEyebrow(color: FFColor.accent)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week \(game.week)")
                        .font(.ffTitle)
                        .foregroundStyle(FFColor.textPrimary)
                    Text(game.opponent.isEmpty ? scoring.label : "vs \(game.opponent) · \(scoring.label)")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(total.fpString)
                        .font(.ffStatLarge)
                        .foregroundStyle(FFColor.textPrimary)
                    Text("PTS").ffEyebrow(color: FFColor.textTertiary)
                }
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func componentsCard(_ components: [Fantasy.ScoreComponent], total: Double) -> some View {
        VStack(spacing: 0) {
            ForEach(components) { c in
                HStack(alignment: .firstTextBaseline, spacing: FFSpace.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                        Text(c.detail)
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    Spacer()
                    Text(signed(c.points))
                        .font(.ffStatSmall)
                        .foregroundStyle(c.points < 0 ? FFColor.negative : FFColor.textPrimary)
                }
                .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                .ffHairlineBottom()
            }
            HStack {
                Text("TOTAL").ffEyebrow()
                Spacer()
                Text(total.fpString)
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.accent)
            }
            .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private var emptyCard: some View {
        Text("No scoring stats for this game.")
            .font(.ffBody).foregroundStyle(FFColor.textSecondary)
            .padding(FFSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }

    // Always show the sign so positive contributions read as additive.
    private func signed(_ v: Double) -> String {
        "\(v >= 0 ? "+" : "")\(v.fpString)"
    }
}
