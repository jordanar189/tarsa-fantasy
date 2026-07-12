import SwiftUI
import Combine

// Lineup tab: the single place to view and set your starting lineup for the
// selected league, per week. Rich per-slot context (opponent, DvP matchup,
// Vegas implied total, weather, injury/inactive, lock, projection, actual),
// start/sit advice, and an Optimize button. Edits auto-save the week's frozen
// lineup. Replaces the old modal lineup editor.
struct LineupTabView: View {
    @Environment(AppState.self) private var app

    @State private var week: Int = 1
    @State private var didInit = false
    @State private var starters: [String] = []
    @State private var ir: [String] = []
    @State private var taxi: [String] = []
    @State private var context: WeekContext = .empty
    @State private var pickingSlot: Int? = nil
    @State private var saving = false
    @State private var error: String? = nil
    @State private var activeDraft: Draft? = nil

    private var league: League? { app.selectedLeague }
    private var team: FantasyTeam? { league.flatMap { app.myTeam(in: $0) } }
    private var config: RosterConfig { league?.rosterConfig ?? .default }
    private var leaguePlayers: [String: Player] {
        guard let league else { return [:] }
        return Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
    }
    private var slots: [LineupSlot] { config.starterSlots }
    private var contextKey: String { "\(app.selectedLeagueID ?? "")-\(week)" }

    private var bench: [String] {
        guard let team else { return [] }
        let starting = Set(starters.filter { !$0.isEmpty })
        let reserved = Set(ir).union(taxi)
        return team.roster.filter { !starting.contains($0) && !reserved.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Lineup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .leagueSwitcher()
            // Typed destinations, declared once so any NavigationLink in
            // this screen (score banner, draft callout, future contextual
            // links) routes here.
            .navigationDestination(for: LineupDestination.self) { dest in
                switch dest {
                case .matchup:            MatchupTabView()
                case .draftRoom(let id):  DraftRoomView(leagueID: id)
                }
            }
        }
        .onAppear {
            if !didInit { week = defaultWeek; didInit = true }
        }
        .task(id: contextKey) { await reload() }
        // Draft status doesn't depend on the week, so it refreshes on league
        // switch only — plus on pop-back (content.onAppear) so the callout
        // clears right after a draft completes or a mock is discarded.
        .task(id: app.selectedLeagueID) { await refreshDraftStatus() }
        // Live games: realtime pushes update the player snapshot, but the
        // WeekContext captured above is frozen — recompute it so actuals,
        // projections, and "yet to play" track the live banner. Debounced:
        // realtime delivers one event per player row, hundreds per minute.
        .onReceive(
            NotificationCenter.default.publisher(for: .liveScoresUpdated)
                .debounce(for: .seconds(2), scheduler: RunLoop.main)
        ) { note in
            guard let season = note.userInfo?["season"] as? Int,
                  season == league?.season,
                  !saving else { return }
            Task { await reload() }
        }
        .sheet(item: Binding(
            get: { pickingSlot.map { SlotRef(index: $0) } },
            set: { pickingSlot = $0?.index }
        )) { ref in
            slotPicker(slot: ref.index)
        }
    }

    private struct SlotRef: Identifiable { let index: Int; var id: Int { index } }

    // Typed destinations for the Lineup tab's navigation stack. Keeps the call
    // sites (NavigationLink(value:)) free of view-construction boilerplate and
    // lets us route from anywhere in the lineup screen without threading state.
    enum LineupDestination: Hashable {
        case matchup
        case draftRoom(String)
    }

    private func refreshDraftStatus() async {
        guard let league else { activeDraft = nil; return }
        let draft = await app.draft(leagueID: league.id)
        activeDraft = (draft?.status == .complete) ? nil : draft
    }

    // Prominent entry into the draft room whenever this league has an
    // unfinished draft. LIVE gets the accent treatment; scheduled shows the
    // start time.
    @ViewBuilder
    private var draftCallout: some View {
        if let draft = activeDraft, let league {
            NavigationLink(value: LineupDestination.draftRoom(league.id)) {
                HStack(spacing: FFSpace.m) {
                    Image(systemName: draft.status == .live ? "dot.radiowaves.left.and.right" : "calendar.badge.clock")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(draft.status == .live ? FFColor.accent : FFColor.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.status == .live ? "Draft is live" :
                             draft.status == .paused ? "Draft paused" : "Draft scheduled")
                            .font(.ffHeadline)
                            .foregroundStyle(FFColor.textPrimary)
                        Text(draft.status == .live
                             ? "Jump into the draft room — picks are rolling."
                             : "Starts \(draft.startsAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .padding(FFSpace.l)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(draft.status == .live ? FFColor.accent.opacity(0.5) : FFColor.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        if league == nil {
            Spacer()
        } else if team == nil {
            spectator
        } else {
            ScrollView {
                VStack(spacing: FFSpace.l) {
                    draftCallout
                    scoreBanner
                    weekPicker
                    totalsCard
                    if let error {
                        Text(error).font(.ffCaption).foregroundStyle(FFColor.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    adviceBanner
                    startersCard
                    benchCard
                    if config.ir > 0 { irCard }
                    if config.taxi > 0 { taxiCard }
                    lineupLocksFooter
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.s)
                .padding(.bottom, 80)
            }
            .refreshable {
                guard !saving else { return }
                await reload()
                await refreshDraftStatus()
            }
            // Re-check on pop-back from the draft room so the callout clears
            // as soon as a draft completes or a mock is discarded.
            .onAppear { Task { await refreshDraftStatus() } }
        }
    }

    private var spectator: some View {
        VStack(spacing: FFSpace.s) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No team in this league")
                .font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
            Text("Claim a team to set your lineup here.")
                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Score banner (me vs opp hero)

    // Mirror the math used by MatchupTabView's SideModel so the two screens
    // never disagree on score, projection, or remaining starters. Returns nil
    // for weeks the viewer isn't playing (off weeks, bye, playoff TBD).
    private func bannerSide(_ t: FantasyTeam, label: String) -> BannerSideRender {
        guard let league else {
            return BannerSideRender(shortName: label, actual: 0, projectedFinal: 0,
                                    remaining: 0, played: false)
        }
        let score = Fantasy.teamWeekScore(
            players: leaguePlayers, team: t, config: league.rosterConfig,
            week: week, scoring: league.scoring, settings: league.scoringSettings
        )
        let starters = score.roster.filter { $0.slot.isStarter }
        var projFinal = 0.0
        var remaining = 0
        var anyPlayed = false
        for e in starters where !e.playerID.isEmpty {
            projFinal += context.liveOrProjected(e.playerID)
            if context.hasPlayed(e.playerID) { anyPlayed = true }
            if !context.hasPlayed(e.playerID), context.opponent(forTeam: e.team) != nil { remaining += 1 }
        }
        return BannerSideRender(
            shortName: t.shortLabel,
            actual: score.total,
            projectedFinal: Fantasy.round2(projFinal),
            remaining: remaining,
            played: anyPlayed
        )
    }

    private func resolveBannerSides() -> (mine: BannerSideRender, opp: BannerSideRender)? {
        guard let league, let mine = team else { return nil }
        let oppTeam: FantasyTeam?
        if week > league.regularSeasonWeeks {
            let bracket = Fantasy.playoffBracket(league: league, players: leaguePlayers)
            let round = bracket.rounds.first { week >= $0.week && week <= $0.endWeek }
            let game = round?.games.first { $0.top.teamID == mine.id || $0.bottom.teamID == mine.id }
            let oppID = game.flatMap { $0.top.teamID == mine.id ? $0.bottom.teamID : $0.top.teamID }
            oppTeam = oppID.flatMap { id in league.teams.first { $0.id == id } }
        } else {
            let result = Fantasy.scoreboard(league: league, players: leaguePlayers, week: week)
            let m = result.matchups.first { $0.home.teamID == mine.id || $0.away.teamID == mine.id }
            let oppID = m.flatMap { $0.home.teamID == mine.id ? $0.away.teamID : $0.home.teamID }
            oppTeam = league.teams.first { $0.id == oppID }
        }
        guard let oppTeam else { return nil }
        return (bannerSide(mine, label: "YOU"), bannerSide(oppTeam, label: "OPP"))
    }

    @ViewBuilder
    private var scoreBanner: some View {
        if let sides = resolveBannerSides() {
            NavigationLink(value: LineupDestination.matchup) {
                ScoreBannerCard(mine: sides.mine, opp: sides.opp, week: week)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Footer caption

    @ViewBuilder
    private var lineupLocksFooter: some View {
        if canEdit {
            Text("Lineups lock at each player's kickoff.")
                .font(.ffMicro).tracking(0.6)
                .foregroundStyle(FFColor.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, FFSpace.s)
        }
    }

    // MARK: - Week picker

    private var selectableWeeks: [Int] {
        guard let league else { return [1] }
        var weeks = league.schedule.map(\.week)
        if league.playoffTeams >= 2 {
            weeks.append(contentsOf: league.playoffStartWeek...league.playoffEndWeek)
        }
        return weeks.isEmpty ? [1] : weeks
    }

    private var defaultWeek: Int {
        guard let league else { return 1 }
        let weeks = selectableWeeks
        let target: Int
        if league.isTest { target = max(1, league.simulatedWeek ?? 1) }
        else { target = Fantasy.currentWeek(players: app.players(season: league.season)) }
        return min(max(target, weeks.first ?? 1), weeks.last ?? 1)
    }

    private var weekPicker: some View {
        HStack {
            Text("WEEK").ffEyebrow()
            Spacer()
            if saving {
                ProgressView().scaleEffect(0.7).tint(FFColor.accent)
                Text("Saving…").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
            Menu {
                Picker("Week", selection: $week) {
                    ForEach(selectableWeeks, id: \.self) { w in Text("Week \(w)").tag(w) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Week \(week)").font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(FFColor.textTertiary)
                }
            }
        }
    }

    // MARK: - Totals

    private var projectedTotal: Double {
        Fantasy.round2(starters.filter { !$0.isEmpty }.reduce(0) { $0 + context.liveOrProjected($1) })
    }
    private var actualTotal: Double {
        Fantasy.round2(starters.filter { !$0.isEmpty }.reduce(0) { $0 + (context.actualPoints($1) ?? 0) })
    }
    private var anyPlayed: Bool { starters.contains { !$0.isEmpty && context.hasPlayed($0) } }

    private var totalsCard: some View {
        HStack(alignment: .center, spacing: FFSpace.l) {
            BigStat(
                label: "Projected",
                value: projectedTotal.fpString,
                tint: FFColor.accent,
                alignment: .leading,
                size: .medium
            )
            if anyPlayed {
                Rectangle().fill(FFColor.border).frame(width: 1, height: 44)
                BigStat(
                    label: "Actual",
                    value: actualTotal.fpString,
                    tint: FFColor.textPrimary,
                    alignment: .leading,
                    size: .medium
                )
            }
            Button { optimize() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text("Optimize")
                }
                .font(.ffCaption.bold())
                .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                .background(FFColor.accentSoft, in: Capsule())
                .foregroundStyle(FFColor.accent)
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .fixedSize()
        }
        // Plain card — the score banner above is this screen's one hero.
        .ffCard()
    }

    // MARK: - Start/sit advice

    // Bench players projected higher than the eligible starter they could
    // replace (excludes locked players on either side).
    private var adviceSuggestions: [(slot: Int, benchID: String, gain: Double)] {
        guard !context.projections.isEmpty else { return [] }
        var out: [(Int, String, Double)] = []
        var claimed = Set<String>()
        for (idx, pid) in starters.enumerated() {
            let slot = slots[idx]
            if context.isLocked(pid) { continue }
            let starterProj = pid.isEmpty ? -1 : context.liveOrProjected(pid)
            let candidate = bench
                .filter { !claimed.contains($0) && !context.isLocked($0) }
                .filter { p in leaguePlayers[p].map { slot.accepts(position: $0.position) } ?? false }
                .max { context.liveOrProjected($0) < context.liveOrProjected($1) }
            if let candidate, context.liveOrProjected(candidate) > starterProj + 0.5 {
                out.append((idx, candidate, Fantasy.round2(context.liveOrProjected(candidate) - max(0, starterProj))))
                claimed.insert(candidate)
            }
        }
        return out
    }

    @ViewBuilder
    private var adviceBanner: some View {
        let suggestions = adviceSuggestions
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(FFColor.warning)
                    Text("START/SIT").ffEyebrow(color: FFColor.warning)
                    Spacer()
                    Button("Apply all") { optimize() }
                        .font(.ffCaption.bold()).foregroundStyle(FFColor.accent)
                        .disabled(!canEdit)
                }
                ForEach(suggestions, id: \.benchID) { s in
                    if let p = leaguePlayers[s.benchID] {
                        Text(adviceLine(for: s, player: p))
                            .font(.ffCaption)
                    }
                }
            }
            .ffCard()
        }
    }

    // Composes the muted prefix + bold positive gain into a single AttributedString.
    // Replaces the deprecated Text + Text concatenation (iOS 26+).
    private func adviceLine(for s: (slot: Int, benchID: String, gain: Double),
                            player: Player) -> AttributedString {
        var prefix = AttributedString("Start \(name(s.benchID, player)) (\(player.position)) — projected ")
        prefix.foregroundColor = FFColor.textSecondary
        var gain = AttributedString("+\(s.gain.fpString)")
        gain.foregroundColor = FFColor.positive
        gain.inlinePresentationIntent = .stronglyEmphasized
        prefix.append(gain)
        return prefix
    }

    // MARK: - Starters

    private var startersCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("STARTERS").ffEyebrow()
            VStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                    starterRow(idx: idx, slot: slot)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
        }
    }

    private func starterRow(idx: Int, slot: LineupSlot) -> some View {
        let pid = idx < starters.count ? starters[idx] : ""
        let player = pid.isEmpty ? nil : leaguePlayers[pid]
        let locked = !pid.isEmpty && context.isLocked(pid)
        // The row button edits the slot; the avatar+name region is a player
        // link (inner gesture wins). No `.disabled` — that would also kill
        // the inner link on locked rows, which used to make them dead taps.
        return Button {
            if canEdit && !locked { pickingSlot = idx }
        } label: {
            HStack(spacing: FFSpace.m) {
                Text(slot.label)
                    .font(.ffMicro.bold())
                    .foregroundStyle(FFColor.positionTint(slot.label))
                    .frame(width: 38, alignment: .leading)
                if let player {
                    HStack(spacing: FFSpace.m) {
                        PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                            contextLine(pid: pid, player: player)
                        }
                    }
                    .playerLink(pid)
                } else {
                    emptyDot
                    Text("Empty").font(.ffBody).foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                pointsColumn(pid: pid)
                if canEdit {
                    Image(systemName: locked ? "lock.fill" : "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(locked ? FFColor.warning : FFColor.textTertiary)
                }
            }
            .padding(.horizontal, FFSpace.m).padding(.vertical, FFSpace.s)
            .ffHairlineBottom()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bench

    private var benchCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("BENCH").ffEyebrow()
            if bench.isEmpty {
                emptyHint("No bench players.")
            } else {
                VStack(spacing: 0) {
                    ForEach(bench, id: \.self) { pid in benchRow(pid) }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
            }
        }
    }

    private func benchRow(_ pid: String) -> some View {
        let player = leaguePlayers[pid]
        let locked = context.isLocked(pid)
        let canStart = canEdit && !locked && firstOpenSlot(for: pid) != nil
        return HStack(spacing: FFSpace.m) {
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    contextLine(pid: pid, player: player)
                }
                .playerLink(pid)
            } else {
                emptyDot
                Text(pid).font(.ffBody).foregroundStyle(FFColor.textTertiary)
            }
            Spacer()
            pointsColumn(pid: pid)
            if canEdit {
                if config.ir > 0 && ir.count < config.ir && (context.injury(pid) != nil || context.isInactive(pid)) {
                    smallButton("IR", filled: false) { toIR(pid) }
                }
                if config.taxi > 0 && taxi.count < config.taxi
                    && Fantasy.taxiEligible(player, maxExperience: config.taxiMaxExperience) {
                    smallButton("Taxi", filled: false) { toTaxi(pid) }
                }
                smallButton("Start", filled: canStart) {
                    if let slot = firstOpenSlot(for: pid) { setStarter(slot: slot, pid: pid) }
                }
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, FFSpace.m).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - IR

    private var irCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("INJURED RESERVE").ffEyebrow()
                Spacer()
                Text("\(ir.count)/\(config.ir)").font(.ffStatSmall).foregroundStyle(FFColor.textTertiary)
            }
            if ir.isEmpty {
                emptyHint("Stash injured players here to free a roster spot.")
            } else {
                VStack(spacing: 0) {
                    ForEach(ir, id: \.self) { pid in irRow(pid) }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
            }
        }
    }

    private func irRow(_ pid: String) -> some View {
        let player = leaguePlayers[pid]
        return HStack(spacing: FFSpace.m) {
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: player.position)
                        if let team, let v = app.playerValue(teamID: team.id, playerID: pid) {
                            PlayerValueBadge(value: v)
                        }
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        if let inj = context.injury(pid) { InjuryBadge(injury: inj) }
                    }
                }
                .playerLink(pid)
            } else {
                emptyDot
                Text(pid).font(.ffBody).foregroundStyle(FFColor.textTertiary)
            }
            Spacer()
            if canEdit { smallButton("Activate", filled: false) { activate(pid) } }
        }
        .padding(.horizontal, FFSpace.m).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - Taxi

    private var taxiCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("TAXI SQUAD").ffEyebrow()
                Spacer()
                Text("\(taxi.count)/\(config.taxi)").font(.ffStatSmall).foregroundStyle(FFColor.textTertiary)
            }
            if taxi.isEmpty {
                emptyHint(config.taxiMaxExperience == 0
                          ? "Stash rookies here to free a roster spot."
                          : "Stash players with ≤ \(config.taxiMaxExperience) year\(config.taxiMaxExperience == 1 ? "" : "s") of experience to free a roster spot.")
            } else {
                VStack(spacing: 0) {
                    ForEach(taxi, id: \.self) { pid in taxiRow(pid) }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
            }
        }
    }

    private func taxiRow(_ pid: String) -> some View {
        let player = leaguePlayers[pid]
        return HStack(spacing: FFSpace.m) {
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: player.position)
                        if let team, let v = app.playerValue(teamID: team.id, playerID: pid) {
                            PlayerValueBadge(value: v)
                        }
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        if let exp = player.profile?.experienceDisplay {
                            Text(exp).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        }
                    }
                }
                .playerLink(pid)
            } else {
                emptyDot
                Text(pid).font(.ffBody).foregroundStyle(FFColor.textTertiary)
            }
            Spacer()
            if canEdit { smallButton("Activate", filled: false) { activateFromTaxi(pid) } }
        }
        .padding(.horizontal, FFSpace.m).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - Shared row bits

    private func name(_ pid: String, _ player: Player) -> String {
        guard let team else { return player.name }
        return app.nickname(teamID: team.id, playerID: pid) ?? player.name
    }

    @ViewBuilder
    private func contextLine(pid: String, player: Player) -> some View {
        let opp = context.opponent(forTeam: player.team)
        let rating = context.rating(position: player.position, opponent: opp)
        let value = team.flatMap { app.playerValue(teamID: $0.id, playerID: pid) }
        HStack(spacing: 6) {
            PositionPill(position: player.position)
            if let value { PlayerValueBadge(value: value) }
            if let opp {
                Text("vs \(opp)").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            } else {
                Text("BYE").font(.ffMicro).foregroundStyle(FFColor.warning)
            }
            if rating != .unknown { MatchupPill(rating: rating, compact: true) }
            if let it = context.impliedTotal(forTeam: player.team) {
                Text(String(format: "%.0f", it)).font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
            if context.isInactive(pid) {
                Text("INA").font(.ffMicro.bold())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(FFColor.negative.opacity(0.18), in: Capsule())
                    .foregroundStyle(FFColor.negative)
            } else if let inj = context.injury(pid) {
                Text(inj.badge).font(.ffMicro.bold())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(FFColor.warning.opacity(0.18), in: Capsule())
                    .foregroundStyle(FFColor.warning)
            }
            if let g = context.game(forTeam: player.team), !g.isIndoor,
               (g.windMph ?? 0) >= 15 || g.precipitation == "rain" || g.precipitation == "snow" {
                Image(systemName: g.precipitation == "snow" ? "snowflake"
                      : (g.precipitation == "rain" ? "cloud.rain" : "wind"))
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(FFColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func pointsColumn(pid: String) -> some View {
        if pid.isEmpty {
            Text("—").font(.ffStatSmall).foregroundStyle(FFColor.textTertiary)
        } else if let actual = context.actualPoints(pid) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(actual.fpString).font(.ffStatMedium).foregroundStyle(FFColor.textPrimary)
                Text("proj \(context.projectedPoints(pid).map { $0.fpString } ?? "—")")
                    .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(context.projectedPoints(pid).map { $0.fpString } ?? "—")
                    .font(.ffStatMedium).foregroundStyle(FFColor.accent)
                Text("proj").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
        }
    }

    private var emptyDot: some View {
        ZStack {
            Circle().fill(FFColor.surfaceElevated)
            Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(FFColor.textTertiary)
        }
        .frame(width: 34, height: 34)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 0.5))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(FFSpace.m)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
    }

    private func smallButton(_ label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.ffCaption.bold())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(filled ? FFColor.accent : FFColor.surfaceElevated, in: Capsule())
                .foregroundStyle(filled ? FFColor.bg : FFColor.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slot picker

    private func slotPicker(slot idx: Int) -> some View {
        let slot = slots[idx]
        let candidates = bench.filter {
            guard let p = leaguePlayers[$0] else { return false }
            return slot.accepts(position: p.position) && !context.isLocked($0)
        }.sorted { context.liveOrProjected($0) > context.liveOrProjected($1) }
        return NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        Button {
                            setStarter(slot: idx, pid: ""); pickingSlot = nil
                        } label: {
                            HStack {
                                emptyDot
                                Text("Leave empty").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m).ffHairlineBottom()
                        }
                        .buttonStyle(.plain)
                        if candidates.isEmpty {
                            Text("No eligible bench players for \(slot.label).")
                                .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                                .frame(maxWidth: .infinity).padding(.vertical, FFSpace.xl)
                        } else {
                            ForEach(candidates, id: \.self) { pid in
                                Button {
                                    setStarter(slot: idx, pid: pid); pickingSlot = nil
                                } label: { candidateRow(pid) }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fill \(slot.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { pickingSlot = nil }.foregroundStyle(FFColor.accent) } }
            .hostsPlayerProfileSheet()
        }
        .presentationDetents([.medium, .large])
    }

    // Tapping the row picks the player for the slot; the avatar alone is the
    // profile link so the primary action keeps the big tap target.
    private func candidateRow(_ pid: String) -> some View {
        let player = leaguePlayers[pid]
        return HStack(spacing: FFSpace.m) {
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 32)
                    .playerLink(pid)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    contextLine(pid: pid, player: player)
                }
            }
            Spacer()
            pointsColumn(pid: pid)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s).ffHairlineBottom()
    }

    // MARK: - Edit gating + mutations

    // Editing a past week's frozen lineup is pointless; allow the default
    // (current/upcoming) week and beyond. Sims always editable for their week.
    private var canEdit: Bool {
        guard team != nil else { return false }
        if let league, league.isTest { return true }
        return week >= defaultWeek
    }

    private func firstOpenSlot(for pid: String) -> Int? {
        guard let p = leaguePlayers[pid] else { return nil }
        // `starters` is briefly empty before the async reload populates it, so
        // never index it by a slot index without a bounds check.
        if let empty = slots.indices.first(where: { $0 < starters.count && starters[$0].isEmpty && slots[$0].accepts(position: p.position) }) {
            return empty
        }
        return slots.indices.first(where: { $0 < starters.count && slots[$0].accepts(position: p.position) && !context.isLocked(starters[$0]) })
    }

    private func setStarter(slot: Int, pid: String) {
        guard slot < starters.count, !context.isLocked(starters[slot]) else { return }
        if !pid.isEmpty {
            ir.removeAll { $0 == pid }
            taxi.removeAll { $0 == pid }
            if let existing = starters.firstIndex(of: pid) { starters[existing] = "" }
        }
        starters[slot] = pid
        persist()
    }

    private func toIR(_ pid: String) {
        guard ir.count < config.ir else { return }
        if let i = starters.firstIndex(of: pid) { starters[i] = "" }
        taxi.removeAll { $0 == pid }
        if !ir.contains(pid) { ir.append(pid) }
        persist()
    }

    private func activate(_ pid: String) {
        ir.removeAll { $0 == pid }
        persist()
    }

    private func toTaxi(_ pid: String) {
        guard taxi.count < config.taxi else { return }
        if let i = starters.firstIndex(of: pid) { starters[i] = "" }
        ir.removeAll { $0 == pid }
        if !taxi.contains(pid) { taxi.append(pid) }
        persist()
    }

    private func activateFromTaxi(_ pid: String) {
        taxi.removeAll { $0 == pid }
        persist()
    }

    private func optimize() {
        guard canEdit else { return }
        let reserved = Set(ir).union(taxi)
        let ranked = (team?.roster ?? [])
            .filter { !reserved.contains($0) && !context.isLocked($0) }
            .compactMap { pid -> (id: String, pos: String, pts: Double)? in
                guard let p = leaguePlayers[pid] else { return nil }
                return (pid, p.position, context.liveOrProjected(pid))
            }
            .sorted { $0.pts > $1.pts }

        var assignment = starters
        if assignment.count != slots.count { assignment = Array(repeating: "", count: slots.count) }
        // Keep locked starters in place; fill the rest.
        var used = Set<String>()
        for i in slots.indices where context.isLocked(assignment[i]) { used.insert(assignment[i]) }
        let order = slots.indices.sorted { i, j in
            if slots[i].flexibility != slots[j].flexibility {
                return slots[i].flexibility < slots[j].flexibility
            }
            return i < j
        }
        for i in order where !context.isLocked(assignment[i]) {
            if let pick = ranked.first(where: { !used.contains($0.id) && slots[i].accepts(position: $0.pos) }) {
                assignment[i] = pick.id
                used.insert(pick.id)
            } else {
                assignment[i] = ""
            }
        }
        starters = assignment
        persist()
    }

    // MARK: - Load + save

    private func reload() async {
        guard let league, let team = app.myTeam(in: league) else { return }
        let resolved = Fantasy.resolveLineup(
            team: team, players: leaguePlayers, config: config,
            scoring: league.scoring, settings: league.scoringSettings, week: week
        )
        starters = resolved.starters
        ir = team.ir.filter { team.roster.contains($0) }
        // Honor taxi membership only while taxi slots are configured, so a
        // disabled taxi doesn't strand players off the bench (matches the
        // resolveLineup / optimalWeekPoints / WaiverClaimSheet guards).
        taxi = config.taxi > 0 ? team.taxi.filter { team.roster.contains($0) } : []
        context = await app.weekContext(league: league, week: week)
    }

    private func persist() {
        guard let league, let team = app.myTeam(in: league) else { return }
        let snapStarters = starters
        let snapIR = ir
        let snapTaxi = taxi
        saving = true
        Task {
            do {
                if let updated = try await app.setLineup(team: team, week: week, starters: snapStarters, ir: snapIR, taxi: snapTaxi) {
                    app.selectedLeague = updated
                }
            } catch {
                self.error = error.localizedDescription
                Haptics.error()
                // The edit was applied optimistically — roll the UI back to
                // the server's lineup instead of showing a state that never
                // persisted.
                await reload()
            }
            saving = false
        }
    }
}

// MARK: - Score banner view components

// Hero card at the top of the Lineup tab: this week's matchup at a glance.
// Big tabular scores for both sides, win-probability bar, "X yet to play"
// summary, and a live/final state chip. Tapping pushes the full Matchup
// screen onto the lineup stack. Sized to read at a glance from across the
// room (the score numbers are the visual anchor of the lineup screen).
//
// Built entirely from shared hero primitives — same recipe everywhere a
// scoreboard-grade surface appears in the app.
private struct ScoreBannerCard: View {
    let mine: LineupTabView.BannerSideRender
    let opp: LineupTabView.BannerSideRender
    let week: Int

    private var leading: Bool { mine.actual >= opp.actual }
    private var anyPlayed: Bool { mine.played || opp.played }
    private var allDone: Bool {
        mine.played && opp.played && mine.remaining == 0 && opp.remaining == 0
    }
    private var stateChip: StateChip {
        if allDone        { return StateChip(state: .final,     label: "Final · Week \(week)") }
        if anyPlayed      { return StateChip(state: .live,      label: "Live · Week \(week)") }
        return                       StateChip(state: .scheduled, label: "Week \(week)")
    }
    private var trailingNote: String {
        if anyPlayed && !allDone { return "\(mine.remaining + opp.remaining) yet to play" }
        if !anyPlayed            { return "Tap to view matchup" }
        return "Final"
    }
    private var winProb: Double {
        MatchupMath.winProbability(
            myFinal: mine.projectedFinal,
            oppFinal: opp.projectedFinal,
            remainingStarters: mine.remaining + opp.remaining
        )
    }

    var body: some View {
        VStack(spacing: FFSpace.m) {
            HStack {
                stateChip
                Spacer()
                Text(trailingNote.uppercased())
                    .font(.ffMicro).tracking(1.2)
                    .foregroundStyle(FFColor.textTertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: FFSpace.s) {
                // Your total is the screen's one ffStatHero headline; the
                // opponent steps down a tier so the eye lands on your side.
                BigStat(
                    label: mine.shortName,
                    value: mine.actual.fpString,
                    caption: "proj \(mine.projectedFinal.fpString)",
                    tint: leading && anyPlayed ? FFColor.accent : FFColor.textPrimary,
                    alignment: .leading,
                    size: .hero
                )
                Text("VS")
                    .font(.ffMicro.bold()).tracking(1.2)
                    .foregroundStyle(FFColor.textTertiary)
                    .padding(.horizontal, 4)
                BigStat(
                    label: opp.shortName,
                    value: opp.actual.fpString,
                    caption: "proj \(opp.projectedFinal.fpString)",
                    tint: !leading && anyPlayed && opp.actual > mine.actual ? FFColor.accent : FFColor.textPrimary,
                    alignment: .trailing,
                    size: .large
                )
            }

            WinBar(myPercent: winProb)
        }
        .ffHeroCard(accentStripe: leading && anyPlayed)
        .contentShape(RoundedRectangle(cornerRadius: FFRadius.l))
    }
}

// Render-only DTO consumed by ScoreBannerCard. Kept on the parent type so
// the private banner struct above can reach it without re-exporting the
// internal BannerSide.
extension LineupTabView {
    struct BannerSideRender {
        let shortName: String
        let actual: Double
        let projectedFinal: Double
        let remaining: Int
        let played: Bool
    }
}
