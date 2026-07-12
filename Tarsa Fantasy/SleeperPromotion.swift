import Foundation

// Pure value-mapping from a read-only Sleeper import (ImportedLeague/Season)
// onto the app's native league primitives, so an import can be *promoted* into
// a real, playable Tarsa league. No I/O or networking — AppState drives the
// actual league creation + roster writes; this file just translates Sleeper's
// shapes into ours. Lives apart from Fantasy.swift so the pure domain layer
// stays free of any Sleeper knowledge.
enum SleeperPromotion {

    // Sleeper roster slots → our RosterConfig. Sleeper labels its bench "BN",
    // injured reserve "IR", taxi "TAXI". Every Sleeper flex variant has a
    // native slot: SUPER_FLEX → superflex (QB-eligible), WRRB_FLEX → W/R,
    // REC_FLEX → W/T, and the IDP family (DL / LB / DB / IDP_FLEX) maps 1:1.
    static func rosterConfig(from positions: [String]) -> RosterConfig {
        func count(_ matches: (String) -> Bool) -> Int { positions.filter(matches).count }
        let qb        = count { $0 == "QB" }
        let rb        = count { $0 == "RB" }
        let wr        = count { $0 == "WR" }
        let te        = count { $0 == "TE" }
        let flex      = count { $0 == "FLEX" }
        let superflex = count { $0 == "SUPER_FLEX" }
        let wrFlex    = count { $0 == "WRRB_FLEX" }
        let recFlex   = count { $0 == "REC_FLEX" }
        let k         = count { $0 == "K" }
        let def       = count { $0 == "DEF" || $0 == "DST" }
        let dl        = count { $0 == "DL" || $0 == "DE" || $0 == "DT" }
        let lb        = count { $0 == "LB" || $0 == "ILB" || $0 == "OLB" }
        let db        = count { $0 == "DB" || $0 == "CB" || $0 == "S" || $0 == "SS" || $0 == "FS" }
        let idpFlex   = count { $0 == "IDP_FLEX" }
        let bench     = count { $0 == "BN" }
        let ir        = count { $0 == "IR" }
        // An empty / unusual position list falls back to the default starter
        // spine so the league is still playable rather than slot-less.
        if qb + rb + wr + te + flex + superflex + wrFlex + recFlex + k + def
            + dl + lb + db + idpFlex == 0 { return .default }
        return RosterConfig(
            qb: qb, rb: rb, wr: wr, te: te,
            flex: flex, superflex: superflex, wrFlex: wrFlex, recFlex: recFlex,
            k: k, def: def,
            dl: dl, lb: lb, db: db, idpFlex: idpFlex,
            bench: bench, ir: ir
        )
    }

    // Sleeper's derived scoring label → our preset. Used as the base carrier;
    // exact per-stat weights come from `scoringSettings(from:fallback:)` when
    // the import captured them.
    static func scoring(fromLabel label: String) -> Scoring {
        switch label.lowercased() {
        case "ppr":                          return .ppr
        case "half-ppr", "half ppr", "half": return .half
        default:                             return .standard
        }
    }

    // Sleeper settings.type — only true dynasty (2) promotes with roster
    // carryover. Keeper leagues (1) promote as redraft: per-player keeper
    // rules aren't modeled yet, and carrying every roster forward would be
    // further from the league's actual rules than keeping none.
    static func isDynasty(leagueType: Int?) -> Bool { leagueType == 2 }

    // Sleeper waiver_type 2 = FAAB with a season budget; everything else maps
    // onto rolling priority (Sleeper's "reverse standings" re-sorts weekly,
    // which we don't model — rolling is the closest behavior).
    static func waiverSettings(waiverType: Int?, waiverBudget: Int?) -> WaiverSettings {
        var s = WaiverSettings.default
        if waiverType == 2 {
            s.mode = .faab
            s.faabBudget = waiverBudget ?? 100
        }
        return s
    }

    // Sleeper's raw per-stat weights → our ScoringSettings. Sleeper stores
    // yardage as points-per-yard (0.04) while our knobs are yards-per-point
    // (25), so those invert. Stats our engine doesn't score (2-pt, return
    // TDs, bonuses) are ignored. Returns nil when the result matches the
    // fallback preset exactly — the precomputed-fields fast path is both
    // cheaper and slightly more accurate (it includes 2-pt / return TDs).
    static func scoringSettings(from raw: [String: Double]?, fallback: Scoring) -> ScoringSettings? {
        guard let raw, !raw.isEmpty else { return nil }
        var s = ScoringSettings.preset(fallback)
        func setYardsPerPoint(_ key: String, _ apply: (Double) -> Void) {
            guard let perYard = raw[key] else { return }
            apply(perYard > 0 ? 1.0 / perYard : 0)
        }
        setYardsPerPoint("pass_yd") { s.passingYardsPerPoint = $0 }
        setYardsPerPoint("rush_yd") { s.rushingYardsPerPoint = $0 }
        setYardsPerPoint("rec_yd")  { s.receivingYardsPerPoint = $0 }
        if let v = raw["pass_td"]  { s.passingTD = v }
        if let v = raw["pass_int"] { s.interception = v }
        if let v = raw["rush_td"]  { s.rushingTD = v }
        if let v = raw["rec_td"]   { s.receivingTD = v }
        if let v = raw["rec"]      { s.reception = v }
        if let v = raw["fum_lost"] { s.fumbleLost = v }
        // Kicking: Sleeper buckets FG makes finer than our three tiers —
        // average its sub-40 buckets into the under-40 knob.
        let under40 = ["fgm_0_19", "fgm_20_29", "fgm_30_39"].compactMap { raw[$0] }
        if !under40.isEmpty { s.fgUnder40 = under40.reduce(0, +) / Double(under40.count) }
        if let v = raw["fgm_40_49"] { s.fg40to49 = v }
        if let v = raw["fgm_50p"] ?? raw["fgm_50_59"] { s.fg50plus = v }
        if let v = raw["xpm"]    { s.patMade = v }
        if let v = raw["fgmiss"] { s.fgMissed = v }
        if let v = raw["xpmiss"] { s.patMissed = v }
        if let v = raw["sack"]    { s.defSack = v }
        if let v = raw["int"]     { s.defInterception = v }
        if let v = raw["fum_rec"] { s.defFumbleRecovery = v }
        if let v = raw["def_td"]  { s.defTouchdown = v }
        if let v = raw["safe"]    { s.defSafety = v }
        // IDP. Sleeper's combined-tackle knob (idp_tkl) applies to solo AND
        // assist when the league doesn't split them — (solo + ast) × w is
        // exactly total tackles × w — while explicit solo/assist values win.
        if let v = raw["idp_tkl"] { s.idpSoloTackle = v; s.idpAssistTackle = v }
        if let v = raw["idp_tkl_solo"] { s.idpSoloTackle = v }
        if let v = raw["idp_tkl_ast"]  { s.idpAssistTackle = v }
        if let v = raw["idp_tkl_loss"] { s.idpTackleForLoss = v }
        if let v = raw["idp_sack"]     { s.idpSack = v }
        if let v = raw["idp_qb_hit"]   { s.idpQbHit = v }
        if let v = raw["idp_int"]      { s.idpInterception = v }
        if let v = raw["idp_pass_def"] { s.idpPassDefended = v }
        if let v = raw["idp_ff"]       { s.idpForcedFumble = v }
        if let v = raw["idp_fum_rec"]  { s.idpFumbleRecovery = v }
        if let v = raw["idp_def_td"] ?? raw["idp_td"] { s.idpTouchdown = v }
        if let v = raw["idp_safe"] ?? raw["idp_safety"] { s.idpSafety = v }
        return s.matchesPreset(fallback) ? nil : s
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
