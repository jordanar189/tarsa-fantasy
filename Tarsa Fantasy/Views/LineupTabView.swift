import SwiftUI

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
    @State private var context: WeekContext = .empty
    @State private var loadingContext = false
    @State private var pickingSlot: Int? = nil
    @State private var saving = false
    @State private var error: String? = nil

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
        let irSet = Set(ir)
        return team.roster.filter { !starting.contains($0) && !irSet.contains($0) }
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
        }
        .onAppear {
            if !didInit { week = defaultWeek; didInit = true }
        }
        .task(id: contextKey) { await reload() }
        .sheet(item: Binding(
            get: { pickingSlot.map { SlotRef(index: $0) } },
            set: { pickingSlot = $0?.index }
        )) { ref in
            slotPicker(slot: ref.index)
        }
    }

    private struct SlotRef: Identifiable { let index: Int; var id: Int { index } }

    @ViewBuilder
    private var content: some View {
        if league == nil {
            Spacer()
        } else if team == nil {
            spectator
        } else {
            ScrollView {
                VStack(spacing: FFSpace.l) {
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
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.s)
                .padding(.bottom, 80)
            }
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

    // MARK: - Week picker

    private var selectableWeeks: [Int] {
        guard let league else { return [1] }
        var weeks = league.schedule.map(\.week)
        if league.playoffTeams >= 2 {
            let rounds = max(1, Int(ceil(log2(Double(league.playoffTeams)))))
            for r in 0..<rounds { weeks.append(league.playoffStartWeek + r) }
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
        HStack(spacing: FFSpace.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PROJECTED").ffEyebrow(color: FFColor.textTertiary)
                Text(projectedTotal.fpString).font(.ffStatLarge).foregroundStyle(FFColor.accent)
            }
            if anyPlayed {
                Rectangle().fill(FFColor.border).frame(width: 1, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTUAL").ffEyebrow(color: FFColor.textTertiary)
                    Text(actualTotal.fpString).font(.ffStatLarge).foregroundStyle(FFColor.textPrimary)
                }
            }
            Spacer()
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
        }
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
                        Text("Start \(name(s.benchID, p)) (\(p.position)) — projected +\(s.gain.fpString)")
                            .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                    }
                }
            }
            .ffCard()
        }
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
        return Button {
            if canEdit && !locked { pickingSlot = idx }
        } label: {
            HStack(spacing: FFSpace.m) {
                Text(slot.label)
                    .font(.ffMicro.bold())
                    .foregroundStyle(FFColor.positionTint(slot.label))
                    .frame(width: 38, alignment: .leading)
                if let player {
                    PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                        contextLine(pid: pid, player: player)
                    }
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
        .disabled(!canEdit || locked)
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
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        if let inj = context.injury(pid) { InjuryBadge(injury: inj) }
                    }
                }
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

    // MARK: - Shared row bits

    private func name(_ pid: String, _ player: Player) -> String {
        guard let team else { return player.name }
        return app.nickname(teamID: team.id, playerID: pid) ?? player.name
    }

    @ViewBuilder
    private func contextLine(pid: String, player: Player) -> some View {
        let opp = context.opponent(forTeam: player.team)
        let rating = context.rating(position: player.position, opponent: opp)
        HStack(spacing: 6) {
            PositionPill(position: player.position)
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
        }
        .presentationDetents([.medium, .large])
    }

    private func candidateRow(_ pid: String) -> some View {
        let player = leaguePlayers[pid]
        return HStack(spacing: FFSpace.m) {
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 32)
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
        if let empty = slots.indices.first(where: { starters[$0].isEmpty && slots[$0].accepts(position: p.position) }) {
            return empty
        }
        return slots.indices.first(where: { slots[$0].accepts(position: p.position) && !context.isLocked(starters[$0]) })
    }

    private func setStarter(slot: Int, pid: String) {
        guard slot < starters.count, !context.isLocked(starters[slot]) else { return }
        if !pid.isEmpty {
            ir.removeAll { $0 == pid }
            if let existing = starters.firstIndex(of: pid) { starters[existing] = "" }
        }
        starters[slot] = pid
        persist()
    }

    private func toIR(_ pid: String) {
        guard ir.count < config.ir else { return }
        if let i = starters.firstIndex(of: pid) { starters[i] = "" }
        if !ir.contains(pid) { ir.append(pid) }
        persist()
    }

    private func activate(_ pid: String) {
        ir.removeAll { $0 == pid }
        persist()
    }

    private func optimize() {
        guard canEdit else { return }
        let irSet = Set(ir)
        let ranked = (team?.roster ?? [])
            .filter { !irSet.contains($0) && !context.isLocked($0) }
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
            if slots[i] == .flex && slots[j] != .flex { return false }
            if slots[j] == .flex && slots[i] != .flex { return true }
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
        loadingContext = true
        context = await app.weekContext(league: league, week: week)
        loadingContext = false
    }

    private func persist() {
        guard let league, let team = app.myTeam(in: league) else { return }
        let snapStarters = starters
        let snapIR = ir
        saving = true
        Task {
            do {
                if let updated = try await app.setLineup(team: team, week: week, starters: snapStarters, ir: snapIR) {
                    app.selectedLeague = updated
                }
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
