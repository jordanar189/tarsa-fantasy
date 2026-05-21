import Foundation

// Shared support for the Lineup and Matchup tabs: a per-week bundle of the
// data both screens need (projections, schedule, DvP, injuries, inactives) with
// convenience lookups, plus the win-probability model.

struct WeekContext {
    let week: Int
    let scoring: Scoring
    let players: [String: Player]
    let schedule: [NFLGame]
    let dvpByPosition: [String: [String: DvPEntry]]
    let injuries: [String: Injury]
    let inactives: Set<String>
    let projections: [String: PlayerProjection]

    static let empty = WeekContext(
        week: 0, scoring: .ppr, players: [:], schedule: [],
        dvpByPosition: [:], injuries: [:], inactives: [], projections: [:]
    )

    func game(forTeam team: String) -> NFLGame? {
        let t = team.uppercased()
        guard !t.isEmpty else { return nil }
        return schedule.first { $0.week == week && ($0.home == t || $0.away == t) }
    }

    func opponent(forTeam team: String) -> String? {
        game(forTeam: team)?.opponent(of: team.uppercased())
    }

    func rating(position: String, opponent: String?) -> MatchupRating {
        guard let opponent else { return .unknown }
        return MatchupRating.from(rank: dvpByPosition[position.uppercased()]?[opponent]?.rank)
    }

    func impliedTotal(forTeam team: String) -> Double? {
        game(forTeam: team)?.impliedTotal(for: team.uppercased())
    }

    func projection(_ playerID: String) -> PlayerProjection? { projections[playerID] }
    func projectedPoints(_ playerID: String) -> Double? { projections[playerID]?.points }

    func hasPlayed(_ playerID: String) -> Bool {
        players[playerID]?.games.contains { $0.week == week } ?? false
    }

    func actualPoints(_ playerID: String) -> Double? {
        guard let g = players[playerID]?.games.first(where: { $0.week == week }) else { return nil }
        return Fantasy.round2(g.points(scoring: scoring))
    }

    func isLocked(_ playerID: String) -> Bool {
        Fantasy.isPlayerLocked(playerID: playerID, week: week, players: players)
    }

    func injury(_ playerID: String) -> Injury? { injuries[playerID] }
    func isInactive(_ playerID: String) -> Bool { inactives.contains(playerID) }

    // A player's contribution to "projected final": their actual points once
    // they've played, otherwise their projection (0 on a bye).
    func liveOrProjected(_ playerID: String) -> Double {
        if let actual = actualPoints(playerID) { return actual }
        return projectedPoints(playerID) ?? 0
    }
}

enum MatchupMath {
    // Win probability from the projected final margin. Variance grows with the
    // number of starters yet to play; a finished game lands near (but not
    // exactly at) 0/100. Logistic approximation of the normal CDF.
    static func winProbability(myFinal: Double, oppFinal: Double, remainingStarters: Int) -> Double {
        let margin = myFinal - oppFinal
        let sd = max(4.0, sqrt(Double(max(remainingStarters, 0))) * 9.0 + 4.0)
        let z = margin / sd
        let p = 1.0 / (1.0 + exp(-1.702 * z))
        return min(0.99, max(0.01, p))
    }
}
