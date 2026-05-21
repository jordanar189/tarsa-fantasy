import SwiftUI

// Weekly start/sit editor. Set a team's starting lineup for a specific week,
// move players to/from the bench, and stash injured players on IR. Players
// whose NFL game has already kicked off for the week are locked and can't be
// moved. Saving freezes the lineup for that week so future edits don't
// rewrite past results.
struct LineupEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let team: FantasyTeam
    let week: Int
    let onSave: (League) -> Void

    @State private var starters: [String]
    @State private var ir: [String]
    @State private var pickingSlot: Int? = nil
    @State private var saving = false
    @State private var error: String? = nil
    @State private var injuries: [String: Injury] = [:]

    init(league: League, team: FantasyTeam, week: Int, onSave: @escaping (League) -> Void) {
        self.league = league
        self.team = team
        self.week = week
        self.onSave = onSave
        let config = league.rosterConfig
        var base = team.weeklyLineups[week] ?? team.starters
        if base.count != config.starterCount {
            base = Array(repeating: "", count: config.starterCount)
        }
        _starters = State(initialValue: base)
        // Drop any IR ids that are no longer on the roster (e.g. dropped while
        // on IR) so the IR slot count stays accurate.
        _ir = State(initialValue: team.ir.filter { team.roster.contains($0) })
    }

    private var config: RosterConfig { league.rosterConfig }
    private var players: [String: Player] {
        Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
    }
    private var slots: [LineupSlot] { config.starterSlots }

    private var bench: [String] {
        let starting = Set(starters.filter { !$0.isEmpty })
        let irSet = Set(ir)
        return team.roster.filter { !starting.contains($0) && !irSet.contains($0) }
    }

    private func locked(_ pid: String) -> Bool {
        !pid.isEmpty && Fantasy.isPlayerLocked(playerID: pid, week: week, players: players)
    }

    // The team's nickname for a player when set, otherwise the real name.
    private func displayName(_ pid: String, _ player: Player) -> String {
        app.nickname(teamID: team.id, playerID: pid) ?? player.name
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.l) {
                        if let error {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        startersCard
                        benchCard
                        if config.ir > 0 { irCard }
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.vertical, FFSpace.l)
                }
            }
            .navigationTitle("Week \(week) lineup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .foregroundStyle(FFColor.accent)
                        .disabled(saving)
                }
            }
            .task {
                injuries = await app.injuries(for: league)
                autoFillIfEmpty()
            }
            .sheet(item: Binding(
                get: { pickingSlot.map { SlotRef(index: $0) } },
                set: { pickingSlot = $0?.index }
            )) { ref in
                slotPicker(slot: ref.index)
            }
        }
    }

    struct SlotRef: Identifiable { let index: Int; var id: Int { index } }

    // MARK: - Starters

    private var startersCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("STARTERS").ffEyebrow()
                Spacer()
                Text("\(filledStarters)/\(config.starterCount)")
                    .font(.ffStatSmall)
                    .foregroundStyle(filledStarters == config.starterCount ? FFColor.positive : FFColor.warning)
            }
            VStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                    starterRow(idx: idx, slot: slot)
                }
            }
            Text("Tap a slot to swap in an eligible player. Locked players have already played this week.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }

    private var filledStarters: Int { starters.filter { !$0.isEmpty }.count }

    private func starterRow(idx: Int, slot: LineupSlot) -> some View {
        let pid = starters[idx]
        let player = pid.isEmpty ? nil : players[pid]
        let isLocked = locked(pid)
        return Button {
            if !isLocked { pickingSlot = idx }
        } label: {
            HStack(spacing: FFSpace.m) {
                Text(slot.label)
                    .font(.ffMicro.bold())
                    .foregroundStyle(FFColor.positionTint(slot.label))
                    .frame(width: 40, alignment: .leading)
                if let player {
                    PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                        HStack(spacing: 6) {
                            PositionPill(position: player.position)
                            Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                            statusBadge(pid)
                        }
                    }
                } else {
                    emptyDot
                    Text("Empty").font(.ffBody).foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                if isLocked {
                    Text("LOCKED").font(.ffMicro.bold()).foregroundStyle(FFColor.warning)
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            .padding(.horizontal, FFSpace.s)
            .padding(.vertical, FFSpace.s)
            .ffHairlineBottom()
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
    }

    // MARK: - Bench

    private var benchCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("BENCH").ffEyebrow()
            if bench.isEmpty {
                Text("No bench players.").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(bench, id: \.self) { pid in
                        benchRow(pid)
                    }
                }
            }
        }
        .ffCard()
    }

    private func benchRow(_ pid: String) -> some View {
        let player = players[pid]
        let isLocked = locked(pid)
        let canStart = !isLocked && firstOpenSlot(for: pid) != nil
        return HStack(spacing: FFSpace.m) {
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: player.position)
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        statusBadge(pid)
                    }
                }
            } else {
                emptyDot
                Text(pid).font(.ffBody).foregroundStyle(FFColor.textTertiary)
            }
            Spacer()
            if isLocked {
                Text("LOCKED").font(.ffMicro.bold()).foregroundStyle(FFColor.warning)
            } else {
                if config.ir > 0 && ir.count < config.ir {
                    smallButton("IR", filled: false) { toIR(pid) }
                }
                smallButton("Start", filled: canStart) {
                    if let slot = firstOpenSlot(for: pid) { setStarter(slot: slot, pid: pid) }
                }
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, FFSpace.s)
        .padding(.vertical, FFSpace.s)
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
                Text("No players on IR. Stash injured players here to free a roster spot.")
                    .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(ir, id: \.self) { pid in
                        irRow(pid)
                    }
                }
            }
        }
        .ffCard()
    }

    private func irRow(_ pid: String) -> some View {
        let player = players[pid]
        return HStack(spacing: FFSpace.m) {
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: player.position)
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        statusBadge(pid)
                    }
                }
            } else {
                emptyDot
                Text(pid).font(.ffBody).foregroundStyle(FFColor.textTertiary)
            }
            Spacer()
            smallButton("Activate", filled: false) { activate(pid) }
        }
        .padding(.horizontal, FFSpace.s)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - Slot picker sheet

    private func slotPicker(slot idx: Int) -> some View {
        let slot = slots[idx]
        let candidates = bench.filter {
            guard let p = players[$0] else { return false }
            return slot.accepts(position: p.position) && !locked($0)
        }
        return NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        Button {
                            setStarter(slot: idx, pid: "")
                            pickingSlot = nil
                        } label: {
                            HStack {
                                emptyDot
                                Text("Leave empty").font(.ffBody).foregroundStyle(FFColor.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                            .ffHairlineBottom()
                        }
                        .buttonStyle(.plain)
                        if candidates.isEmpty {
                            Text("No eligible bench players for \(slot.label).")
                                .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                                .frame(maxWidth: .infinity).padding(.vertical, FFSpace.xl)
                        } else {
                            ForEach(candidates, id: \.self) { pid in
                                Button {
                                    setStarter(slot: idx, pid: pid)
                                    pickingSlot = nil
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { pickingSlot = nil }.foregroundStyle(FFColor.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func candidateRow(_ pid: String) -> some View {
        let player = players[pid]
        let pts = player.map { Fantasy.summary($0, scoring: league.scoring).points } ?? 0
        return HStack(spacing: FFSpace.m) {
            if let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(pid, player)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: player.position)
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        statusBadge(pid)
                    }
                }
            }
            Spacer()
            Text(pts.fpString).font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // MARK: - Mutations

    private func setStarter(slot: Int, pid: String) {
        guard !locked(starters[slot]) else { return }
        if !pid.isEmpty {
            ir.removeAll { $0 == pid }
            if let j = starters.firstIndex(of: pid), j != slot { starters[j] = "" }
        }
        starters[slot] = pid
    }

    private func firstOpenSlot(for pid: String) -> Int? {
        guard let p = players[pid] else { return nil }
        return slots.indices.first { starters[$0].isEmpty && slots[$0].accepts(position: p.position) }
    }

    private func toIR(_ pid: String) {
        guard ir.count < config.ir, !locked(pid) else { return }
        if let j = starters.firstIndex(of: pid) { starters[j] = "" }
        if !ir.contains(pid) { ir.append(pid) }
    }

    private func activate(_ pid: String) {
        ir.removeAll { $0 == pid }
    }

    private func autoFillIfEmpty() {
        guard starters.allSatisfy({ $0.isEmpty }) else { return }
        starters = Fantasy.autoFillLineup(
            roster: team.roster, players: players, config: config,
            scoring: league.scoring, settings: league.scoringSettings, ir: Set(ir)
        )
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            guard let updated = try await app.setLineup(
                team: team, week: week, starters: starters, ir: ir
            ) else { dismiss(); return }
            onSave(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Bits

    @ViewBuilder
    private func statusBadge(_ pid: String) -> some View {
        if let inj = injuries[pid] {
            Text(inj.badge)
                .font(.ffMicro.bold())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(FFColor.warning.opacity(0.18), in: Capsule())
                .foregroundStyle(FFColor.warning)
        }
    }

    private var emptyDot: some View {
        ZStack {
            Circle().fill(FFColor.surfaceElevated)
            Image(systemName: "person.fill")
                .font(.system(size: 13))
                .foregroundStyle(FFColor.textTertiary)
        }
        .frame(width: 32, height: 32)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 0.5))
    }

    private func smallButton(_ label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.ffCaption.bold())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(filled ? FFColor.accent : FFColor.surfaceElevated, in: Capsule())
                .foregroundStyle(filled ? FFColor.bg : FFColor.textSecondary)
        }
        .buttonStyle(.plain)
    }
}
