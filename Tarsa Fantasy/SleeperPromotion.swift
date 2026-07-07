import Foundation

// Pure value-mapping from a read-only Sleeper import (ImportedLeague/Season)
// onto the app's native league primitives, so an import can be *promoted* into
// a real, playable Tarsa league. No I/O or networking — AppState drives the
// actual league creation + roster writes; this file just translates Sleeper's
// shapes into ours. Lives apart from Fantasy.swift so the pure domain layer
// stays free of any Sleeper knowledge.
enum SleeperPromotion {

    // Sleeper roster slots → our RosterConfig. Sleeper labels its bench "BN",
    // injured reserve "IR", taxi "TAXI". Every Sleeper flex variant now has a
    // native slot: SUPER_FLEX → superflex (QB-eligible), WRRB_FLEX → W/R,
    // REC_FLEX → W/T. Only IDP_FLEX (defensive players, which the engine
    // doesn't model) collapses onto the generic FLEX.
    static func rosterConfig(from positions: [String]) -> RosterConfig {
        func count(_ matches: (String) -> Bool) -> Int { positions.filter(matches).count }
        let qb        = count { $0 == "QB" }
        let rb        = count { $0 == "RB" }
        let wr        = count { $0 == "WR" }
        let te        = count { $0 == "TE" }
        let flex      = count { $0 == "FLEX" || $0 == "IDP_FLEX" }
        let superflex = count { $0 == "SUPER_FLEX" }
        let wrFlex    = count { $0 == "WRRB_FLEX" }
        let recFlex   = count { $0 == "REC_FLEX" }
        let k         = count { $0 == "K" }
        let def       = count { $0 == "DEF" || $0 == "DST" }
        let bench     = count { $0 == "BN" }
        let ir        = count { $0 == "IR" }
        // An empty / unusual position list (or an IDP-only league we can't map)
        // falls back to the default starter spine so the league is still
        // playable rather than slot-less.
        if qb + rb + wr + te + flex + superflex + wrFlex + recFlex + k + def == 0 { return .default }
        return RosterConfig(
            qb: qb, rb: rb, wr: wr, te: te,
            flex: flex, superflex: superflex, wrFlex: wrFlex, recFlex: recFlex,
            k: k, def: def, bench: bench, ir: ir
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

    // Local app player ids (nflverse GSIS / "DEF_<TEAM>") for every player on a
    // Sleeper roster — active players plus IR/taxi — resolved against the live
    // nflverse `snapshot`, deduped, and dropping Sleeper's "0" empty-slot
    // placeholder.
    //
    // Sleeper's own `gsis_id` (carried on ImportedPlayer.appID) is used when it
    // points at a real player in the snapshot; otherwise we fall back to a
    // normalized name (+ position/team) match. Sleeper leaves `gsis_id` blank for
    // a large share of players, and an unmapped id would silently drop the player
    // into free agency instead of onto the promoted roster — the name fallback is
    // what keeps a promoted team looking like its Sleeper original. Players with
    // no match in the snapshot can't be rostered (the engine has no record of
    // them), so they're dropped.
    // `nameIndex` is a full scan of the snapshot, so callers promoting a whole
    // league should build it once (via `nameIndex(for:)`) and pass it in rather
    // than rebuilding it for every team. Omitting it keeps the single-call API.
    static func resolveRoster(
        for team: ImportedTeam,
        lookup: [String: ImportedPlayer],
        snapshot: [String: Player],
        nameIndex precomputed: [String: [String]]? = nil
    ) -> [String] {
        // With no local snapshot to resolve against (e.g. season data failed to
        // load), fall back to Sleeper's raw gsis/DEF ids so promotion still
        // produces rosters rather than empty teams.
        let index = snapshot.isEmpty ? [:] : (precomputed ?? nameIndex(for: snapshot))
        var seen: Set<String> = []
        var out: [String] = []
        var ids = team.players
        ids += team.reserve
        ids += team.taxi
        for sid in ids where sid != "0" {
            guard let player = lookup[sid] else { continue }
            let resolved = snapshot.isEmpty
                ? player.appID
                : localID(for: player, snapshot: snapshot, nameIndex: index)
            guard let resolved, seen.insert(resolved).inserted else { continue }
            out.append(resolved)
        }
        return out
    }

    // Resolve a single imported player to a local players_cache id, preferring
    // Sleeper's gsis/DEF id and falling back to a name match.
    private static func localID(
        for player: ImportedPlayer,
        snapshot: [String: Player],
        nameIndex: [String: [String]]
    ) -> String? {
        if let appID = player.appID, snapshot[appID] != nil { return appID }

        let key = normalizedName(player.name)
        guard !key.isEmpty, let candidates = nameIndex[key], !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }

        // Disambiguate same-name players by position, then current team, then
        // who actually logged games (the fringe namesake usually has none).
        let pos = player.position.uppercased()
        let team = player.team.uppercased()
        func rank(_ id: String) -> (Int, Int, Int) {
            let p = snapshot[id]
            return (
                p?.position.uppercased() == pos ? 1 : 0,
                p?.team.uppercased() == team ? 1 : 0,
                p?.games.count ?? 0
            )
        }
        // Tie-break on the (unique) player id so the choice is stable across runs
        // and devices when two candidates rank identically — Dictionary iteration
        // order, which `candidates` inherits, is otherwise unspecified.
        return candidates.max {
            let ra = rank($0), rb = rank($1)
            return ra == rb ? $0 < $1 : ra < rb
        }
    }

    // normalized name -> local player ids. A full scan of the snapshot — build it
    // once per promotion and hand it to `resolveRoster`, not once per team.
    static func nameIndex(for snapshot: [String: Player]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for (id, p) in snapshot {
            let key = normalizedName(p.name)
            guard !key.isEmpty else { continue }
            index[key, default: []].append(id)
        }
        return index
    }

    private static let nameSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "v"]

    // Lowercased, diacritic-folded, punctuation-stripped name with generational
    // suffixes removed, so "D'Andre Swift" / "DeAndre Swift Jr." and Sleeper's
    // vs nflverse's spellings collapse onto the same key. Punctuation becomes a
    // separator (consistently on both sides) so hyphens/periods/apostrophes don't
    // change the token set.
    private static func normalizedName(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let separated = String(folded.map { $0.isLetter || $0 == " " ? $0 : " " })
        let tokens = separated.split(separator: " ").map(String.init).filter { !nameSuffixes.contains($0) }
        return tokens.joined(separator: " ")
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
