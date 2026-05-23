import Foundation

// Pure value-mapping from a read-only Sleeper import (ImportedLeague/Season)
// onto the app's native league primitives, so an import can be *promoted* into
// a real, playable Tarsa league. No I/O or networking — AppState drives the
// actual league creation + roster writes; this file just translates Sleeper's
// shapes into ours. Lives apart from Fantasy.swift so the pure domain layer
// stays free of any Sleeper knowledge.
enum SleeperPromotion {

    // Sleeper roster slots → our RosterConfig. Sleeper labels its bench "BN",
    // injured reserve "IR", taxi "TAXI". Every flex variant (including
    // SUPER_FLEX, which our lineup engine can't model exactly because FLEX
    // never accepts a QB) collapses onto our single FLEX slot.
    static func rosterConfig(from positions: [String]) -> RosterConfig {
        func count(_ matches: (String) -> Bool) -> Int { positions.filter(matches).count }
        let qb    = count { $0 == "QB" }
        let rb    = count { $0 == "RB" }
        let wr    = count { $0 == "WR" }
        let te    = count { $0 == "TE" }
        let flex  = count { ["FLEX", "WRRB_FLEX", "REC_FLEX", "SUPER_FLEX", "IDP_FLEX"].contains($0) }
        let k     = count { $0 == "K" }
        let def   = count { $0 == "DEF" || $0 == "DST" }
        let bench = count { $0 == "BN" }
        let ir    = count { $0 == "IR" }
        // An empty / unusual position list (or an IDP-only league we can't map)
        // falls back to the default starter spine so the league is still
        // playable rather than slot-less.
        if qb + rb + wr + te + flex + k + def == 0 { return .default }
        return RosterConfig(
            qb: qb, rb: rb, wr: wr, te: te,
            flex: flex, k: k, def: def, bench: max(bench, 0), ir: ir
        )
    }

    // Sleeper's derived scoring label → our preset. "Custom" (and anything we
    // don't recognise) maps to standard; custom per-stat weights aren't carried
    // over because the import only captured a coarse label.
    static func scoring(fromLabel label: String) -> Scoring {
        switch label.lowercased() {
        case "ppr":                          return .ppr
        case "half-ppr", "half ppr", "half": return .half
        default:                             return .standard
        }
    }

    // Regular-season length implied by Sleeper's playoff start week (weeks
    // before the postseason). Falls back to a typical 14-week season.
    static func regularSeasonWeeks(from season: ImportedSeason) -> Int {
        if let start = season.playoffWeekStart, start > 1 { return start - 1 }
        return 14
    }

    // App player ids (nflverse GSIS / "DEF_<TEAM>") for every player Sleeper
    // has on this roster — active players plus IR/taxi — deduped, dropping
    // unmapped ids and Sleeper's "0" empty-slot placeholder.
    static func appRosterIDs(for team: ImportedTeam, lookup: [String: ImportedPlayer]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        var ids = team.players
        ids += team.reserve
        ids += team.taxi
        for sid in ids where sid != "0" {
            guard let appID = lookup[sid]?.appID, seen.insert(appID).inserted else { continue }
            out.append(appID)
        }
        return out
    }

    // Final standings of a completed Sleeper season as our archive rows. Team
    // ids are synthesized (Sleeper roster ids aren't app team UUIDs) and only
    // used for list identity in the History tab — head-to-head linkage isn't
    // available for imported history because those managers have no app account.
    static func standingsRows(for season: ImportedSeason) -> [StandingsRow] {
        season.standings.enumerated().map { idx, t in
            StandingsRow(
                id: "sleeper-\(season.season)-\(t.rosterID)",
                name: t.teamName,
                wins: t.wins, losses: t.losses, ties: t.ties,
                pointsFor: Fantasy.round2(t.pointsFor),
                pointsAgainst: Fantasy.round2(t.pointsAgainst),
                games: t.wins + t.losses + t.ties,
                rank: idx + 1
            )
        }
    }
}
