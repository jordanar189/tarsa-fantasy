import Foundation

// App-facing model for a league imported from Sleeper. This is a read-only
// archive: we fetch a Sleeper league (and every prior season reachable via
// `previous_league_id`) once, denormalize it into display-ready value types,
// and persist the result locally via SleeperStore. Nothing here flows into the
// Supabase fantasy engine — imported leagues are browsed, not played, so they
// never touch the scoring / waiver / draft cron pipeline.
//
// All types are plain Codable value types (implicitly Sendable) so the actor
// that builds them can hand them to the MainActor, and so the whole aggregate
// round-trips cleanly to disk.

// A single player as it appears on an imported roster / transaction / draft.
// `appID` is the local players_cache id (nflverse GSIS id for skill players,
// "DEF_<TEAM>" for defenses) when we could map it — that powers tap-through to
// the in-app player profile. When nil we still render Sleeper's own metadata.
struct ImportedPlayer: Codable, Hashable, Identifiable {
    let sleeperID: String
    let appID: String?
    let name: String
    let position: String
    let team: String

    var id: String { sleeperID }
}

struct ImportedTeam: Codable, Hashable, Identifiable {
    let rosterID: Int
    let ownerID: String?
    let teamName: String        // league-specific team name, falling back to owner
    let ownerName: String       // Sleeper display name
    let avatar: String?         // Sleeper avatar id (user or league)
    let wins: Int
    let losses: Int
    let ties: Int
    let pointsFor: Double
    let pointsAgainst: Double
    let players: [String]       // Sleeper player ids on the roster
    let starters: [String]      // Sleeper player ids, in starting-slot order
    let reserve: [String]       // IR
    let taxi: [String]          // taxi squad

    var id: Int { rosterID }

    var record: String { ties > 0 ? "\(wins)-\(losses)-\(ties)" : "\(wins)-\(losses)" }
    var winPct: Double {
        let g = wins + losses + ties
        return g > 0 ? (Double(wins) + 0.5 * Double(ties)) / Double(g) : 0
    }
}

// One side of one weekly matchup. Two ImportedMatchup rows that share a
// (week, matchupID) are opponents; a row with a nil matchupID had no opponent.
struct ImportedMatchup: Codable, Hashable, Identifiable {
    let week: Int
    let matchupID: Int?
    let rosterID: Int
    let points: Double

    var id: String { "\(week)-\(rosterID)" }
}

struct ImportedTransactionMove: Codable, Hashable {
    let player: ImportedPlayer
    let rosterID: Int
}

struct ImportedTransactionPick: Codable, Hashable {
    let season: String
    let round: Int
    let fromRosterID: Int?
    let toRosterID: Int?
}

struct ImportedTransaction: Codable, Hashable, Identifiable {
    let transactionID: String
    let type: String            // "trade" | "waiver" | "free_agent" | "commissioner"
    let status: String
    let week: Int
    let createdAt: Date?
    let rosterIDs: [Int]
    let adds: [ImportedTransactionMove]
    let drops: [ImportedTransactionMove]
    let picks: [ImportedTransactionPick]
    let waiverBid: Int?

    var id: String { transactionID }

    var typeLabel: String {
        switch type {
        case "trade":        return "Trade"
        case "waiver":       return "Waiver"
        case "free_agent":   return "Free agent"
        case "commissioner": return "Commissioner"
        default:             return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct ImportedDraftPick: Codable, Hashable, Identifiable {
    let pickNo: Int
    let round: Int
    let draftSlot: Int
    let rosterID: Int?
    let player: ImportedPlayer

    var id: Int { pickNo }
}

// One Sleeper season of a league. Seasons of the same league chain together
// (via previous_league_id) into an ImportedLeague.
struct ImportedSeason: Codable, Hashable, Identifiable {
    let sleeperLeagueID: String
    let name: String
    let season: String          // "2023"
    let status: String          // "complete" | "in_season" | "pre_draft" | ...
    let scoringLabel: String    // "PPR" | "Half-PPR" | "Standard" | "Custom"
    let avatar: String?
    let rosterPositions: [String]
    let playoffWeekStart: Int?
    let teams: [ImportedTeam]
    let matchups: [ImportedMatchup]
    let transactions: [ImportedTransaction]
    let draftPicks: [ImportedDraftPick]
    // Resolved bios for every Sleeper player id referenced this season (rosters,
    // starters, IR/taxi). Deduped by sleeperID so playerLookup keys are unique.
    let players: [ImportedPlayer]
    let championRosterID: Int?

    var id: String { sleeperLeagueID }
    var seasonYear: Int { Int(season) ?? 0 }

    var teamsByRoster: [Int: ImportedTeam] {
        Dictionary(uniqueKeysWithValues: teams.map { ($0.rosterID, $0) })
    }

    var playerLookup: [String: ImportedPlayer] {
        Dictionary(players.map { ($0.sleeperID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // Teams ranked the way Sleeper does: wins first, then total points scored.
    var standings: [ImportedTeam] {
        teams.sorted {
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            return $0.pointsFor > $1.pointsFor
        }
    }

    // Starting-slot labels (QB/RB/.../FLEX/K/DEF) in roster order, excluding
    // bench / IR / taxi — these line up index-for-index with team.starters.
    var starterSlotLabels: [String] {
        rosterPositions.filter { !["BN", "IR", "TAXI"].contains($0) }
    }

    var weeks: [Int] {
        Array(Set(matchups.map(\.week))).sorted()
    }

    func matchupPairs(week: Int) -> [(a: ImportedMatchup, b: ImportedMatchup?)] {
        let rows = matchups.filter { $0.week == week }
        let grouped = Dictionary(grouping: rows.filter { $0.matchupID != nil }, by: { $0.matchupID! })
        var pairs: [(a: ImportedMatchup, b: ImportedMatchup?)] = []
        for key in grouped.keys.sorted() {
            let sides = grouped[key]!.sorted { $0.rosterID < $1.rosterID }
            pairs.append((a: sides[0], b: sides.count > 1 ? sides[1] : nil))
        }
        // Byes / unpaired rows.
        for row in rows where row.matchupID == nil {
            pairs.append((a: row, b: nil))
        }
        return pairs
    }
}

// A league across all of its Sleeper seasons, newest first. `id` is the root
// (newest) Sleeper league id the user imported.
struct ImportedLeague: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let importedAt: Date
    let seasons: [ImportedSeason]

    var latest: ImportedSeason? { seasons.first }
    var seasonYear: Int { latest?.seasonYear ?? 0 }
    var scoringLabel: String { latest?.scoringLabel ?? "" }
    var teamCount: Int { latest?.teams.count ?? 0 }
}

// MARK: - Lightweight pre-import lookups

// A user's league shown in the import picker before the full (slow) import.
struct SleeperLeagueBrief: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let season: String
    let totalRosters: Int
    let avatar: String?
}

struct SleeperUserBrief: Codable, Hashable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    let avatar: String?
}
