import SwiftUI

// Persistent "on the clock" widget for the draft room. Shows the team
// currently picking, a live countdown dial, and the controls that the
// viewer is allowed to use:
//
//   - Auto-pick toggle: visible if the viewer owns the on-clock team OR is
//     the league commissioner. Server enforces the same auth.
//   - "Make pick for this team" button: commissioner-only — opens the
//     player picker on behalf of someone else. In the Testing Environment,
//     this is how the admin makes bot picks manually.
//
// The widget also displays an "auto" badge when the on-clock team is in
// auto-pick mode so it's obvious why their pick is about to fire.
struct DraftOnTheClockWidget: View {
    let draft: Draft
    let league: League
    let session: Session?
    let onPause: () -> Void
    let onAutoPickToggle: (FantasyTeam, Bool) -> Void
    let onPickForTeam: (FantasyTeam) -> Void
    let onManageTeams: () -> Void

    private var onClockTeam: FantasyTeam? {
        guard let id = draft.teamOnClock(forPick: draft.currentPick) else { return nil }
        return league.teams.first(where: { $0.id == id })
    }

    private var isMyTurn: Bool {
        onClockTeam?.ownerID == session?.userID
    }

    private var isCommish: Bool {
        league.creatorID == session?.userID
    }

    private var canToggleAuto: Bool {
        // Owner can toggle their own team; commissioner can toggle anyone.
        isMyTurn || isCommish
    }

    private var canMakePickForTeam: Bool {
        // Commissioner picking for a team that isn't theirs. The "Make pick"
        // sheet flow is what the testing env uses to step through bot picks.
        isCommish && !isMyTurn && onClockTeam != nil
    }

    private var teamIsOnAuto: Bool {
        guard let id = onClockTeam?.id else { return false }
        return draft.isOnAutoPick(teamID: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack(alignment: .top, spacing: FFSpace.l) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: FFSpace.s) {
                        StateChip(
                            state: isMyTurn ? .live : .scheduled,
                            label: "On the clock"
                        )
                        if teamIsOnAuto {
                            StateChip(state: .auto, label: "Auto")
                        }
                    }
                    Text(onClockTeam?.name ?? "—")
                        .font(.ffTitle.bold())
                        .foregroundStyle(isMyTurn ? FFColor.accent : FFColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(pickLabel)
                        .font(.ffMicro).tracking(1.2)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                if let deadline = draft.pickDeadline {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        countdownDial(remaining: deadline.timeIntervalSinceNow,
                                      total: Double(draft.pickSeconds))
                    }
                }
            }

            controls
        }
        .ffHeroCard(accentStripe: isMyTurn)
    }

    private var pickLabel: String {
        let teamCount = max(draft.pickOrder.count, 1)
        let round = ((draft.currentPick - 1) / teamCount) + 1
        return "Round \(round) · Pick \(draft.currentPick)/\(draft.totalPicks)"
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: FFSpace.s) {
            if canToggleAuto, let team = onClockTeam {
                Button {
                    onAutoPickToggle(team, !teamIsOnAuto)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: teamIsOnAuto ? "bolt.fill" : "bolt")
                            .font(.system(size: 11, weight: .semibold))
                        Text(teamIsOnAuto ? "Auto-pick on" : "Auto-pick off")
                    }
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                    .background(teamIsOnAuto ? FFColor.accent : FFColor.surfaceElevated,
                                in: Capsule())
                    .foregroundStyle(teamIsOnAuto ? FFColor.bg : FFColor.textPrimary)
                }
                .buttonStyle(.plain)
            }
            if canMakePickForTeam, let team = onClockTeam {
                Button {
                    onPickForTeam(team)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Make pick for \(team.name)")
                    }
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                    .overlay(Capsule().strokeBorder(FFColor.accent.opacity(0.5), lineWidth: 1))
                    .foregroundStyle(FFColor.accent)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if isCommish {
                Button {
                    onManageTeams()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Manage teams")
                    }
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.s).padding(.vertical, 6)
                    .background(FFColor.surfaceElevated, in: Capsule())
                    .foregroundStyle(FFColor.textPrimary)
                }
                .buttonStyle(.plain)
                Button {
                    onPause()
                } label: {
                    Text("Pause")
                        .font(.ffCaption.bold())
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
        }
    }

    private func countdownDial(remaining: TimeInterval, total: Double) -> some View {
        let secs = max(0, Int(remaining.rounded(.up)))
        let frac = max(0, min(1, total == 0 ? 0 : remaining / total))
        let warn = remaining <= 10
        return ZStack {
            Circle().stroke(FFColor.border, lineWidth: 4)
            Circle()
                .trim(from: 0, to: frac)
                .stroke(warn ? FFColor.warning : FFColor.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: frac)
            Text("\(secs)")
                .font(.ffStatMedium)
                .foregroundStyle(warn ? FFColor.warning : FFColor.textPrimary)
        }
        .frame(width: 60, height: 60)
    }
}
