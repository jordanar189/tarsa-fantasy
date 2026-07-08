import SwiftUI

// Mock draft: a throwaway live draft against instant-pick bots. The league
// is a normal is_test simulation flagged locally (AppState.mockLeagueIDs);
// when its draft completes the room shows MockDraftGradeCard with the
// discard/keep exit.
struct MockDraftSetupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var teamCount: Int = 10
    @State private var pickSlot: Int? = nil      // nil = random
    @State private var clockSeconds: Int = 20
    @State private var scoring: Scoring = .half
    @State private var creating: Bool = false
    @State private var error: String? = nil

    private var season: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: FFSpace.xl) {
                        header
                        teamCountSection
                        slotSection
                        clockSection
                        scoringSection
                        if let error {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                        }
                        Button {
                            Task { await start() }
                        } label: {
                            HStack {
                                if creating { ProgressView().tint(.white) }
                                Text(creating ? "Setting up…" : "Start mock draft")
                            }
                        }
                        .ffPrimaryButton(disabled: creating)
                        .disabled(creating)
                    }
                    .padding(FFSpace.l)
                }
            }
            .navigationTitle("Mock draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
        }
    }

    private var header: some View {
        Text("Practice against bots that pick instantly. Nothing sticks unless you keep it — the league disappears when you discard the mock.")
            .font(.ffCaption)
            .foregroundStyle(FFColor.textSecondary)
    }

    private var teamCountSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("TEAMS").ffEyebrow()
            Picker("Teams", selection: $teamCount) {
                ForEach([8, 10, 12, 14], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: teamCount) { _, newValue in
                if let slot = pickSlot, slot > newValue { pickSlot = nil }
            }
        }
    }

    private var slotSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("YOUR DRAFT SLOT").ffEyebrow()
            Menu {
                Button("Random") { pickSlot = nil }
                ForEach(1...teamCount, id: \.self) { slot in
                    Button("Pick \(slot)") { pickSlot = slot }
                }
            } label: {
                HStack {
                    Text(pickSlot.map { "Pick \($0)" } ?? "Random")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .overlay(RoundedRectangle(cornerRadius: FFRadius.s).strokeBorder(FFColor.border, lineWidth: 1))
            }
        }
    }

    private var clockSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("PICK CLOCK").ffEyebrow()
            Picker("Clock", selection: $clockSeconds) {
                Text("10s").tag(10)
                Text("20s").tag(20)
                Text("30s").tag(30)
            }
            .pickerStyle(.segmented)
        }
    }

    private var scoringSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("SCORING").ffEyebrow()
            Picker("Scoring", selection: $scoring) {
                ForEach(Scoring.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func start() async {
        creating = true; defer { creating = false }
        do {
            // createMockDraft selects the league; the draft banner takes the
            // user into the room from there.
            _ = try await app.createMockDraft(
                season: season,
                scoring: scoring,
                teamCount: teamCount,
                myPickSlot: pickSlot,
                clockSeconds: clockSeconds
            )
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}

// Post-draft grades for a mock: each team's picks valued against ADP
// (positive = players fell past their market price), plus the discard/keep
// exit. Rendered inside DraftRoomView's complete header.
struct MockDraftGradeCard: View {
    @Environment(AppState.self) private var app

    let league: League
    let draft: Draft

    private struct TeamGrade: Identifiable {
        let id: String
        let name: String
        let isMine: Bool
        let value: Double
        var grade: String = "—"
    }

    @State private var grades: [TeamGrade] = []
    @State private var bestValuePick: (name: String, delta: Double)? = nil
    @State private var discarding: Bool = false
    @State private var confirmingDiscard: Bool = false
    @State private var discardError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            if !grades.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("DRAFT GRADES").ffEyebrow()
                    ForEach(grades) { g in
                        HStack {
                            Text(g.grade)
                                .font(.ffStatSmall)
                                .foregroundStyle(gradeColor(g.grade))
                                .frame(width: 34, alignment: .leading)
                            Text(g.name)
                                .font(.ffBody)
                                .foregroundStyle(FFColor.textPrimary)
                            if g.isMine {
                                Text("YOU").ffEyebrow(color: FFColor.accent)
                            }
                            Spacer()
                            Text(String(format: "%+.0f", g.value))
                                .font(.ffStatSmall)
                                .foregroundStyle(g.value >= 0 ? FFColor.positive : FFColor.negative)
                        }
                        .ffHairlineBottom()
                    }
                    if let steal = bestValuePick {
                        Text("Your best value: \(steal.name), \(Int(steal.delta)) picks past ADP.")
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textSecondary)
                    }
                }
            }
            HStack(spacing: FFSpace.s) {
                Button {
                    confirmingDiscard = true
                } label: {
                    Text(discarding ? "Discarding…" : "Discard mock")
                }
                .ffPrimaryButton(disabled: discarding)
                .disabled(discarding)
                Button {
                    app.keepMockAsSim(leagueID: league.id)
                } label: {
                    Text("Keep as sim league")
                }
                .ffSecondaryButton()
                .disabled(discarding)
            }
            .padding(.top, FFSpace.s)
            if let discardError {
                Text(discardError)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.negative)
            }
        }
        .confirmationDialog("Discard this mock draft?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                Task {
                    discarding = true
                    discardError = nil
                    // On success the delete drops the league selection and
                    // the root swaps home, tearing this screen down for us.
                    let deleted = await app.discardMock(leagueID: league.id)
                    if !deleted {
                        discarding = false
                        discardError = "Couldn't delete the mock — check your connection and try again."
                        Haptics.error()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The practice league and its draft are deleted. This can't be undone.")
        }
        .task(id: draft.id) { await computeGrades() }
    }

    private func gradeColor(_ grade: String) -> Color {
        if grade.hasPrefix("A") { return FFColor.positive }
        if grade.hasPrefix("B") { return FFColor.accent }
        if grade.hasPrefix("C") { return FFColor.warning }
        return FFColor.negative
    }

    private func computeGrades() async {
        let adp = await app.adpForSimulation(season: league.season, scoring: league.scoring)
        let picks = await app.draftPicks(draftID: draft.id)
        guard !picks.isEmpty else { return }
        let players = app.players(season: league.season)
        let myTeamID = league.teams.first(where: { $0.ownerID == app.session?.userID })?.id

        var valueByTeam: [String: Double] = [:]
        var myBest: (name: String, delta: Double)? = nil
        for pick in picks {
            // Positive delta = drafted later than market price = value.
            guard let marketADP = adp[pick.playerID] else { continue }
            let delta = Double(pick.pickNumber) - marketADP
            valueByTeam[pick.teamID, default: 0] += delta
            if pick.teamID == myTeamID, delta > (myBest?.delta ?? 4) {
                let name = players[pick.playerID]?.name ?? pick.playerID
                myBest = (name, delta)
            }
        }

        // Rank → letter. Mocks are for fun; the curve is generous.
        let letters = ["A+", "A", "A-", "B+", "B", "B-", "C+", "C", "C-", "D+", "D", "D-", "F", "F"]
        let ranked = league.teams
            .map { team in
                TeamGrade(id: team.id, name: team.name,
                          isMine: team.id == myTeamID,
                          value: valueByTeam[team.id] ?? 0)
            }
            .sorted { $0.value > $1.value }
        let step = max(1, ranked.count / 4)
        grades = ranked.enumerated().map { idx, g in
            var graded = g
            graded.grade = letters[min(idx * 3 / step, letters.count - 1)]
            return graded
        }
        bestValuePick = myBest
    }
}
