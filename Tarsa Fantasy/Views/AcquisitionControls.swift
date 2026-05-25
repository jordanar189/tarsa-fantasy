import SwiftUI

// Whether — and how — the signed-in user can acquire a player in the selected
// league. Drives the status icon on the Players list and the action button on
// the player profile's Overview tab.
enum PlayerAcquisition: Hashable {
    case addable                                  // free agent — add immediately
    case claimable(Date)                          // on waivers until the given date
    case trade(teamID: String, teamName: String)  // rostered by another team
    case onMyRoster                               // already on your team
    case unavailable                              // no team / game locked / no league

    // Resolve a player's status. `league` is the selected league; `droppedByID`
    // maps player id → most recent drop (used to tell free-agent adds from
    // waiver claims); `week` is the current scoring week (for the lock check).
    static func resolve(
        playerID: String,
        league: League,
        myTeam: FantasyTeam?,
        players: [String: Player],
        droppedByID: [String: DroppedPlayer],
        week: Int
    ) -> PlayerAcquisition {
        if let team = league.teams.first(where: { $0.roster.contains(playerID) }) {
            return team.id == myTeam?.id
                ? .onMyRoster
                : .trade(teamID: team.id, teamName: team.name)
        }
        // Free agent. Need a team to acquire onto, and the game can't be locked.
        guard myTeam != nil else { return .unavailable }
        if Fantasy.isPlayerLocked(playerID: playerID, week: week, players: players) {
            return .unavailable
        }
        if let drop = droppedByID[playerID], drop.isOnWaivers {
            return .claimable(drop.waiverUntil)
        }
        return .addable
    }

    var iconName: String {
        switch self {
        case .addable:    return "plus.circle.fill"
        case .claimable:  return "hourglass.circle.fill"
        case .trade:      return "arrow.left.arrow.right.circle.fill"
        case .onMyRoster: return "checkmark.circle.fill"
        case .unavailable: return "minus.circle.fill"
        }
    }

    // Each state gets its own color so the list reads at a glance.
    var tint: Color {
        switch self {
        case .addable:    return FFColor.positive   // green — grab it
        case .claimable:  return FFColor.warning    // amber — waiver wait
        case .trade:      return FFColor.accent     // cyan — needs a trade
        case .onMyRoster: return FFColor.textSecondary
        case .unavailable: return FFColor.textTertiary
        }
    }

    var label: String {
        switch self {
        case .addable:    return "Add player"
        case .claimable:  return "Claim off waivers"
        case .trade:      return "Propose trade"
        case .onMyRoster: return "On your roster"
        case .unavailable: return "Unavailable"
        }
    }

    var isActionable: Bool {
        switch self {
        case .addable, .claimable, .trade: return true
        case .onMyRoster, .unavailable:    return false
        }
    }
}

// Compact status icon for a player list row. Tappable for actionable states;
// a plain dimmed glyph otherwise.
struct AcquisitionIcon: View {
    let acquisition: PlayerAcquisition
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        if acquisition.isActionable && enabled {
            Button(action: action) {
                Image(systemName: acquisition.iconName)
                    .font(.system(size: 22))
                    .foregroundStyle(acquisition.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(acquisition.label)
        } else {
            Image(systemName: acquisition.iconName)
                .font(.system(size: 22))
                .foregroundStyle(acquisition.tint.opacity(enabled ? 1 : 0.5))
                .accessibilityLabel(acquisition.label)
        }
    }
}

// Full-width labeled action button for the player profile Overview tab.
struct AcquisitionButton: View {
    let acquisition: PlayerAcquisition
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        let interactive = acquisition.isActionable && enabled
        Button(action: { if interactive { action() } }) {
            HStack(spacing: FFSpace.s) {
                Image(systemName: acquisition.iconName)
                Text(acquisition.label).font(.ffBody.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(interactive ? acquisition.tint : FFColor.surfaceElevated, in: Capsule())
            .foregroundStyle(interactive ? FFColor.bg : FFColor.textTertiary)
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
    }
}

// Sheet targets shared by the Players list and the player profile.
struct AddClaimTarget: Identifiable {
    let team: FantasyTeam
    let addPlayer: PlayerSummary
    let isOnWaivers: Bool
    let waiverUntil: Date?
    var id: String { addPlayer.id }
}

struct AcquireTradeTarget: Identifiable {
    let fromTeam: FantasyTeam
    let toTeamID: String
    let playerID: String
    var id: String { playerID }
}
