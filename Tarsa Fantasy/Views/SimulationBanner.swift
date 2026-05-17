import SwiftUI

// Always-visible control surface inside a Simulation league. Lets the
// owner step through simulated weeks, run bot activity manually, and
// toggle whether bots act automatically when the week advances.
struct SimulationBanner: View {
    @Environment(AppState.self) private var app
    let league: League
    let onLeagueUpdate: (League) -> Void

    @AppStorage("simulation.autoBots") private var autoBots: Bool = false
    @State private var working: Bool = false
    @State private var confirmingResetPeriod: Bool = false
    @State private var confirmingResetAll: Bool = false

    private var currentWeek: Int { league.simulatedWeek ?? 0 }
    private var scheduleLen: Int { league.schedule.count }
    private var maxPhase: Int { scheduleLen + 1 }   // postseason index

    private var phaseLabel: String {
        if currentWeek == 0 { return "PRESEASON" }
        if currentWeek > scheduleLen { return "POSTSEASON" }
        return "WEEK \(currentWeek)"
    }

    var body: some View {
        VStack(spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(FFColor.warning)
                    .font(.system(size: 13, weight: .semibold))
                Text("SIMULATION")
                    .ffEyebrow(color: FFColor.warning)
                Spacer()
                Text(phaseLabel)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.accent)
            }

            HStack(spacing: FFSpace.s) {
                stepButton(systemName: "chevron.left", disabled: currentWeek <= 0 || working) {
                    Task { await advance(by: -1) }
                }
                phaseChips
                stepButton(systemName: "chevron.right", disabled: currentWeek >= maxPhase || working) {
                    Task { await advance(by: 1) }
                }
            }

            HStack(spacing: FFSpace.s) {
                Button {
                    Task { await runBots() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Run bot activity")
                    }
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                    .background(FFColor.surfaceElevated, in: Capsule())
                    .foregroundStyle(FFColor.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(working)

                Spacer()

                Toggle(isOn: $autoBots) {
                    Text("Auto bots on advance")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                }
                .toggleStyle(SwitchToggleStyle(tint: FFColor.accent))
                .labelsHidden()
                .scaleEffect(0.85)
                Text("Auto")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }

            HStack(spacing: FFSpace.s) {
                resetButton(label: "Reset period", icon: "arrow.counterclockwise") {
                    confirmingResetPeriod = true
                }
                resetButton(label: "Reset all", icon: "arrow.uturn.left") {
                    confirmingResetAll = true
                }
            }
        }
        .alert("Reset \(phaseLabel.localizedLowercase)?", isPresented: $confirmingResetPeriod) {
            Button("Cancel", role: .cancel) {}
            Button("Reset period", role: .destructive) {
                Task { await resetPeriod() }
            }
        } message: {
            Text("Undoes every transaction, trade, waiver claim, and roster move made at or after \(phaseLabel.localizedLowercase). Rosters revert to the entry state of this period. Can't be undone.")
        }
        .alert("Reset entire simulation?", isPresented: $confirmingResetAll) {
            Button("Cancel", role: .cancel) {}
            Button("Reset all", role: .destructive) {
                Task { await resetAll() }
            }
        } message: {
            Text("Wipes every transaction, trade, waiver, and roster move and snaps back to preseason with the originally drafted rosters. Can't be undone.")
        }
        .ffCard()
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.warning.opacity(0.4), lineWidth: 1)
        )
    }

    private var phaseChips: some View {
        // Compact dots-style indicator: a chip for preseason, each week,
        // postseason. Tap to jump directly.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    chip(label: "PRE", index: 0, isCurrent: currentWeek == 0)
                        .id(0)
                    ForEach(1...scheduleLen, id: \.self) { wk in
                        chip(label: "\(wk)", index: wk, isCurrent: currentWeek == wk)
                            .id(wk)
                    }
                    chip(label: "POST", index: maxPhase, isCurrent: currentWeek == maxPhase)
                        .id(maxPhase)
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 32)
            .onChange(of: currentWeek) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear {
                proxy.scrollTo(currentWeek, anchor: .center)
            }
        }
    }

    private func chip(label: String, index: Int, isCurrent: Bool) -> some View {
        Button {
            Task { await jump(to: index) }
        } label: {
            Text(label)
                .font(.ffMicro).tracking(0.5)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(isCurrent ? FFColor.accent : FFColor.surfaceElevated, in: Capsule())
                .foregroundStyle(isCurrent ? FFColor.bg : FFColor.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private func stepButton(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .padding(8)
                .background(FFColor.surfaceElevated, in: Circle())
                .foregroundStyle(disabled ? FFColor.textTertiary : FFColor.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func advance(by delta: Int) async {
        working = true; defer { working = false }
        if let updated = try? await app.advanceSimulatedWeek(leagueID: league.id, delta: delta) {
            onLeagueUpdate(updated)
            if autoBots && delta > 0 {
                await app.runBotActivity(league: updated)
                if let fresher = await app.league(updated.id) { onLeagueUpdate(fresher) }
            }
        }
    }

    private func jump(to week: Int) async {
        working = true; defer { working = false }
        let delta = week - currentWeek
        if delta == 0 { return }
        if let updated = try? await app.advanceSimulatedWeek(leagueID: league.id, delta: delta) {
            onLeagueUpdate(updated)
            if autoBots && delta > 0 {
                await app.runBotActivity(league: updated)
                if let fresher = await app.league(updated.id) { onLeagueUpdate(fresher) }
            }
        }
    }

    private func runBots() async {
        working = true; defer { working = false }
        await app.runBotActivity(league: league)
        if let fresher = await app.league(league.id) { onLeagueUpdate(fresher) }
    }

    private func resetButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
            }
            .font(.ffCaption.bold())
            .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
            .background(FFColor.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(FFColor.negative.opacity(0.4), lineWidth: 1))
            .foregroundStyle(FFColor.negative)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private func resetPeriod() async {
        working = true; defer { working = false }
        if let updated = await app.resetCurrentPeriod(leagueID: league.id) {
            onLeagueUpdate(updated)
        }
    }

    private func resetAll() async {
        working = true; defer { working = false }
        if let updated = await app.resetAll(leagueID: league.id) {
            onLeagueUpdate(updated)
        }
    }
}
