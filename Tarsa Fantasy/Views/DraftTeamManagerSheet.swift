import SwiftUI

// Commissioner-only sheet for managing every team's auto-pick state in a
// single place. Primary use case: in the Testing Environment, the admin
// owns every team and wants to set autopilot on the bots without having to
// wait for each team's turn. Real leagues can use it too — a commish can
// flip an absent owner into auto-pick or pick on their behalf.
struct DraftTeamManagerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    // Initial draft passed in by the parent. We mirror it into @State so
    // toggle taps re-render the sheet immediately even though the parent's
    // own @State updates don't reliably propagate down through .sheet props.
    let initialDraft: Draft
    let league: League
    // The draft picks so we can compute current pick / on-clock team.
    let picks: [DraftPick]
    let onChanged: (Draft) -> Void
    let onPickForTeam: (FantasyTeam) -> Void

    @State private var draft: Draft
    @State private var working: Bool = false
    @State private var error: String? = nil

    init(draft: Draft, league: League, picks: [DraftPick],
         onChanged: @escaping (Draft) -> Void,
         onPickForTeam: @escaping (FantasyTeam) -> Void) {
        self.initialDraft = draft
        self.league = league
        self.picks = picks
        self.onChanged = onChanged
        self.onPickForTeam = onPickForTeam
        _draft = State(initialValue: draft)
    }

    // Treats "other team" loosely — in a simulation every team is owned by
    // the creator so "other" means "not the creator's primary team". In a
    // real league it means "not the viewer's own team".
    private var viewerTeamID: String? {
        guard let uid = app.session?.userID else { return nil }
        if league.isTest {
            return AppState.primaryTeamID(in: league)
        }
        return league.teams.first(where: { $0.ownerID == uid })?.id
    }

    private var orderedTeams: [FantasyTeam] {
        // Pick-order from the draft if available; otherwise default order.
        let byID = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0) })
        let ordered = draft.pickOrder.compactMap { byID[$0] }
        if ordered.count == league.teams.count { return ordered }
        return league.teams
    }

    private var onClockTeamID: String? {
        draft.teamOnClock(forPick: draft.currentPick)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.l) {
                        batchControls
                        teamList
                        if let error {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                        }
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Manage teams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
        }
    }

    // MARK: - Batch controls

    private var batchControls: some View {
        HStack(spacing: FFSpace.s) {
            Button {
                Task { await setAll(true, includeViewer: false) }
            } label: {
                Text(league.isTest ? "Auto all bots" : "Auto all others")
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                    .background(FFColor.accent, in: Capsule())
                    .foregroundStyle(FFColor.bg)
            }
            .buttonStyle(.plain)
            .disabled(working)

            Button {
                Task { await setAll(false, includeViewer: true) }
            } label: {
                Text("Manual for all")
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                    .overlay(Capsule().strokeBorder(FFColor.border, lineWidth: 1))
                    .foregroundStyle(FFColor.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(working)

            Spacer()
        }
    }

    // MARK: - Team list

    private var teamList: some View {
        VStack(spacing: 0) {
            ForEach(Array(orderedTeams.enumerated()), id: \.element.id) { idx, team in
                teamRow(idx: idx, team: team)
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func teamRow(idx: Int, team: FantasyTeam) -> some View {
        let isOnClock = team.id == onClockTeamID && draft.status == .live
        let isAuto = draft.isOnAutoPick(teamID: team.id)
        let isViewerTeam = team.id == viewerTeamID
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: FFSpace.s) {
                Text("#\(idx + 1)")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textTertiary)
                    .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(team.name)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                        ownerBadge(team: team, isViewerTeam: isViewerTeam)
                        if isOnClock {
                            Text("ON CLOCK").ffEyebrow(color: FFColor.warning)
                        }
                    }
                    Text("\(team.roster.count)/\(league.rosterConfig.totalSize) drafted")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                Button {
                    Task { await toggle(team: team, enabled: !isAuto) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isAuto ? "bolt.fill" : "bolt")
                            .font(.system(size: 10, weight: .semibold))
                        Text(isAuto ? "Auto" : "Off")
                    }
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.s).padding(.vertical, 6)
                    .background(isAuto ? FFColor.accent : FFColor.surfaceElevated, in: Capsule())
                    .foregroundStyle(isAuto ? FFColor.bg : FFColor.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
            if isOnClock {
                Button {
                    onPickForTeam(team)
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Pick now for \(team.name)")
                    }
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.m).padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(FFColor.accent.opacity(0.5), lineWidth: 1))
                    .foregroundStyle(FFColor.accent)
                }
                .buttonStyle(.plain)
                .padding(.leading, 28 + FFSpace.s)
            }
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    @ViewBuilder
    private func ownerBadge(team: FantasyTeam, isViewerTeam: Bool) -> some View {
        if isViewerTeam {
            Text("YOU").ffEyebrow(color: FFColor.accent)
        } else if team.ownerID == nil {
            Text("OPEN").ffEyebrow(color: FFColor.warning)
        } else if league.isTest {
            // Test leagues: every non-admin team is owned by the admin too,
            // so "BOT" reads more usefully than "another manager".
            Text("BOT").ffEyebrow(color: FFColor.textTertiary)
        }
        // Real leagues with another real owner: omit the badge — the team
        // name is self-evident.
    }

    // MARK: - Actions

    private func toggle(team: FantasyTeam, enabled: Bool) async {
        working = true; defer { working = false }
        do {
            if let updated = try await app.setAutoPick(
                draftID: draft.id, teamID: team.id, enabled: enabled
            ) {
                draft = updated
                onChanged(updated)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setAll(_ enabled: Bool, includeViewer: Bool) async {
        working = true; defer { working = false }
        var lastUpdated: Draft? = nil
        do {
            for team in orderedTeams {
                // Skip the viewer's own team unless explicitly included — the
                // batch "auto all others" should leave the commish's own team
                // alone so they can keep picking manually.
                if !includeViewer && team.id == viewerTeamID { continue }
                let currentlyAuto = draft.isOnAutoPick(teamID: team.id)
                if currentlyAuto == enabled { continue }
                if let updated = try await app.setAutoPick(
                    draftID: draft.id, teamID: team.id, enabled: enabled
                ) {
                    lastUpdated = updated
                    draft = updated   // keep the UI in sync after each call
                }
            }
            if let lastUpdated { onChanged(lastUpdated) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
