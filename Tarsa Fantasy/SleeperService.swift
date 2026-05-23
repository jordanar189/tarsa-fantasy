import Foundation

// Read-only client for the public Sleeper API (https://api.sleeper.app/v1).
// No auth required. Responsibilities:
//   • light lookups for the import picker (user, a user's leagues, NFL state)
//   • the full import: given a league id, walk `previous_league_id` back through
//     every season and pull rosters, standings, weekly matchups, transactions,
//     drafts and the playoff bracket, denormalized into ImportedLeague.
//   • mapping Sleeper player ids → local players_cache ids (GSIS for skill
//     players, "DEF_<TEAM>" for defenses) so imported rosters tap through to the
//     in-app player profiles.
//
// Network calls are `static` (so they're not serialized on the actor and can
// run concurrently in task groups); the actor only guards the cached player
// index. Sleeper asks callers to hit /players/nfl at most once per day, so that
// ~5 MB map is cached to disk for 24h and reduced to a slim id→bio index.
actor SleeperService {
    static let shared = SleeperService()

    private static let base = "https://api.sleeper.app/v1"
    private static let avatarBase = "https://sleepercdn.com/avatars/thumbs/"

    // Slim, persisted view of a Sleeper player: just what we render plus the
    // resolved local id for tap-through.
    struct ResolvedPlayer: Codable, Hashable {
        let name: String
        let position: String
        let team: String
        let appID: String?
    }

    private var playerIndex: [String: ResolvedPlayer]? = nil

    // MARK: - Avatars

    nonisolated static func avatarURL(_ id: String?) -> URL? {
        guard let id, !id.isEmpty else { return nil }
        return URL(string: avatarBase + id)
    }

    // MARK: - Light lookups (for the import picker)

    // Current NFL season + week per Sleeper.
    func nflState() async -> (season: Int, week: Int)? {
        guard let s: SLState = try? await Self.fetch("/state/nfl") else { return nil }
        return (Int(s.season) ?? 0, max(s.week ?? s.leg ?? 1, 1))
    }

    func user(username: String) async throws -> SleeperUserBrief {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SleeperError.invalidInput }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        do {
            let u: SLUser = try await Self.fetch("/user/\(encoded)")
            guard let uid = u.userId else { throw SleeperError.userNotFound }
            return SleeperUserBrief(
                id: uid,
                username: u.username ?? trimmed,
                displayName: u.displayName ?? u.username ?? trimmed,
                avatar: u.avatar
            )
        } catch SleeperError.notFound {
            throw SleeperError.userNotFound
        }
    }

    func leagues(userID: String, season: Int) async throws -> [SleeperLeagueBrief] {
        let leagues: [SLLeague] = try await Self.fetch("/user/\(userID)/leagues/nfl/\(season)")
        return leagues.map {
            SleeperLeagueBrief(
                id: $0.leagueId,
                name: $0.name ?? "Untitled league",
                season: $0.season ?? String(season),
                totalRosters: $0.totalRosters ?? 0,
                avatar: $0.avatar
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Full import

    func importLeague(rootLeagueID: String) async throws -> ImportedLeague {
        let root = rootLeagueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw SleeperError.invalidInput }

        let index = try await ensurePlayerIndex()
        let current = await nflState()

        var seasons: [ImportedSeason] = []
        var visited: Set<String> = []
        var cursor: String? = root

        while let id = cursor, !visited.contains(id), seasons.count < 20 {
            visited.insert(id)
            let league: SLLeague
            do {
                league = try await Self.fetch("/league/\(id)")
            } catch SleeperError.notFound {
                if seasons.isEmpty { throw SleeperError.leagueNotFound }
                break
            }
            let season = try await buildSeason(league: league, index: index, currentState: current)
            seasons.append(season)

            let prev = league.previousLeagueId
            cursor = (prev == nil || prev == "0" || prev?.isEmpty == true) ? nil : prev
        }

        guard let newest = seasons.first else { throw SleeperError.leagueNotFound }
        return ImportedLeague(
            id: root,
            name: newest.name,
            importedAt: Date(),
            seasons: seasons
        )
    }

    private func buildSeason(
        league: SLLeague,
        index: [String: ResolvedPlayer],
        currentState: (season: Int, week: Int)?
    ) async throws -> ImportedSeason {
        let id = league.leagueId

        async let usersA: [SLUser]          = Self.optArray("/league/\(id)/users")
        async let rostersA: [SLRoster]      = Self.optArray("/league/\(id)/rosters")
        async let bracketA: [SLBracketMatch] = Self.optArray("/league/\(id)/winners_bracket")
        async let draftsA: [SLDraft]        = Self.optArray("/league/\(id)/drafts")
        let users = await usersA
        let rosters = await rostersA
        let bracket = await bracketA
        let drafts = await draftsA

        let usersByID = Dictionary(uniqueKeysWithValues: users.compactMap { u -> (String, SLUser)? in
            guard let uid = u.userId else { return nil }
            return (uid, u)
        })

        let teams: [ImportedTeam] = rosters.map { r in
            let owner = r.ownerId.flatMap { usersByID[$0] }
            let s = r.settings
            let pf = Double(s?.fpts ?? 0) + Double(s?.fptsDecimal ?? 0) / 100.0
            let pa = Double(s?.fptsAgainst ?? 0) + Double(s?.fptsAgainstDecimal ?? 0) / 100.0
            let teamName = owner?.metadata?.teamName?.nilIfBlank
                ?? owner?.displayName
                ?? "Team \(r.rosterId)"
            return ImportedTeam(
                rosterID: r.rosterId,
                ownerID: r.ownerId,
                teamName: teamName,
                ownerName: owner?.displayName ?? owner?.username ?? "—",
                avatar: owner?.avatar,
                wins: s?.wins ?? 0,
                losses: s?.losses ?? 0,
                ties: s?.ties ?? 0,
                pointsFor: pf,
                pointsAgainst: pa,
                players: r.players ?? [],
                starters: r.starters ?? [],   // keep "0" placeholders so starter slots stay aligned
                reserve: r.reserve ?? [],
                taxi: r.taxi ?? []
            )
        }
        .sorted { $0.rosterID < $1.rosterID }

        // How many weeks to pull. Completed seasons get the full slate
        // (regular + playoffs); an in-progress season only up to "now".
        let isCurrent = currentState.map { String($0.season) == league.season } ?? false
        let maxWeek = (league.status == "complete" || !isCurrent)
            ? 18
            : min(max(currentState?.week ?? 18, 1), 18)

        // Run the three per-week fan-outs concurrently. Each is nonisolated and
        // only touches its parameters + static network helpers, so they overlap
        // instead of running back-to-back on the actor.
        async let matchupsTask     = fetchMatchups(leagueID: id, maxWeek: maxWeek)
        async let transactionsTask = fetchTransactions(leagueID: id, maxWeek: maxWeek, index: index)
        async let draftPicksTask   = fetchDraftPicks(drafts: drafts, index: index)
        let matchups = await matchupsTask
        let transactions = await transactionsTask
        let draftPicks = await draftPicksTask

        // Resolve a bio for every player id any roster references, so the roster
        // tab can render names (rosters carry only raw Sleeper ids).
        var seen: Set<String> = []
        var players: [ImportedPlayer] = []
        for r in rosters {
            let rosterIDs: [String] = (r.players ?? []) + (r.starters ?? []) + (r.reserve ?? []) + (r.taxi ?? [])
            for pid in rosterIDs {
                guard pid != "0", seen.insert(pid).inserted else { continue }
                players.append(resolve(pid, index))
            }
        }

        return ImportedSeason(
            sleeperLeagueID: id,
            name: league.name ?? "Untitled league",
            season: league.season ?? "",
            status: league.status ?? "",
            scoringLabel: Self.scoringLabel(league.scoringSettings),
            avatar: league.avatar,
            rosterPositions: league.rosterPositions ?? [],
            playoffWeekStart: league.settings?.playoffWeekStart,
            teams: teams,
            matchups: matchups,
            transactions: transactions,
            draftPicks: draftPicks,
            players: players,
            championRosterID: Self.champion(from: bracket, leagueComplete: league.status == "complete")
        )
    }

    nonisolated private func fetchMatchups(leagueID: String, maxWeek: Int) async -> [ImportedMatchup] {
        guard maxWeek >= 1 else { return [] }
        var out: [ImportedMatchup] = []
        await withTaskGroup(of: (Int, [SLMatchup]).self) { group in
            for w in 1...maxWeek {
                group.addTask { (w, await Self.optArray("/league/\(leagueID)/matchups/\(w)")) }
            }
            for await (w, rows) in group {
                for r in rows {
                    out.append(ImportedMatchup(
                        week: w, matchupID: r.matchupId,
                        rosterID: r.rosterId, points: r.points ?? 0
                    ))
                }
            }
        }
        return out.sorted { $0.week != $1.week ? $0.week < $1.week : $0.rosterID < $1.rosterID }
    }

    nonisolated private func fetchTransactions(
        leagueID: String, maxWeek: Int, index: [String: ResolvedPlayer]
    ) async -> [ImportedTransaction] {
        guard maxWeek >= 1 else { return [] }
        var raw: [(Int, [SLTransaction])] = []
        await withTaskGroup(of: (Int, [SLTransaction]).self) { group in
            for w in 1...maxWeek {
                group.addTask { (w, await Self.optArray("/league/\(leagueID)/transactions/\(w)")) }
            }
            for await pair in group { raw.append(pair) }
        }
        var out: [ImportedTransaction] = []
        for (week, txns) in raw {
            for t in txns where t.status != "failed" {
                let adds = (t.adds ?? [:]).map { (pid, rid) in
                    ImportedTransactionMove(player: resolve(pid, index), rosterID: rid)
                }.sorted { $0.rosterID != $1.rosterID ? $0.rosterID < $1.rosterID : $0.player.name < $1.player.name }
                let drops = (t.drops ?? [:]).map { (pid, rid) in
                    ImportedTransactionMove(player: resolve(pid, index), rosterID: rid)
                }.sorted { $0.rosterID != $1.rosterID ? $0.rosterID < $1.rosterID : $0.player.name < $1.player.name }
                let picks = (t.draftPicks ?? []).map {
                    ImportedTransactionPick(
                        season: $0.season ?? "",
                        round: $0.round ?? 0,
                        fromRosterID: $0.previousOwnerId,
                        toRosterID: $0.ownerId
                    )
                }
                out.append(ImportedTransaction(
                    transactionID: t.transactionId ?? UUID().uuidString,
                    type: t.type ?? "",
                    status: t.status ?? "",
                    week: t.leg ?? week,
                    createdAt: t.created.map { Date(timeIntervalSince1970: Double($0) / 1000.0) },
                    rosterIDs: t.rosterIds ?? [],
                    adds: adds,
                    drops: drops,
                    picks: picks,
                    waiverBid: t.settings?.waiverBid
                ))
            }
        }
        return out.sorted {
            switch ($0.createdAt, $1.createdAt) {
            case let (a?, b?): return a > b
            case (nil, _?):    return false
            case (_?, nil):    return true
            default:           return $0.week > $1.week
            }
        }
    }

    nonisolated private func fetchDraftPicks(
        drafts: [SLDraft], index: [String: ResolvedPlayer]
    ) async -> [ImportedDraftPick] {
        // Sleeper exposes one draft per league-season for redraft/keeper/dynasty
        // (rookie) drafts, so the first entry is this season's draft. A season
        // with multiple drafts (rare) would only surface the first.
        guard let draftID = drafts.first?.draftId else { return [] }
        let picks: [SLDraftPick] = await Self.optArray("/draft/\(draftID)/picks")
        return picks.compactMap { p in
            guard let pid = p.playerId else { return nil }
            return ImportedDraftPick(
                pickNo: p.pickNo ?? 0,
                round: p.round ?? 0,
                draftSlot: p.draftSlot ?? 0,
                rosterID: p.rosterId,
                player: resolve(pid, index)
            )
        }
        .sorted { $0.pickNo < $1.pickNo }
    }

    // MARK: - Player resolution

    nonisolated private func resolve(_ sleeperID: String, _ index: [String: ResolvedPlayer]) -> ImportedPlayer {
        if let r = index[sleeperID] {
            return ImportedPlayer(sleeperID: sleeperID, appID: r.appID, name: r.name, position: r.position, team: r.team)
        }
        // Defenses key on the team abbreviation (e.g. "KC"); they're sometimes
        // absent from the slim index.
        if sleeperID.count <= 3, sleeperID == sleeperID.uppercased(),
           sleeperID.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil {
            return ImportedPlayer(
                sleeperID: sleeperID, appID: "DEF_\(sleeperID)",
                name: "\(sleeperID) DST", position: "DEF", team: sleeperID
            )
        }
        return ImportedPlayer(sleeperID: sleeperID, appID: nil, name: sleeperID, position: "", team: "")
    }

    // MARK: - Player index (download + 24h disk cache)

    private func ensurePlayerIndex() async throws -> [String: ResolvedPlayer] {
        if let cached = playerIndex { return cached }
        if let disk = Self.loadIndexFromDisk() {
            playerIndex = disk
            return disk
        }
        let raw: [String: SLPlayer] = try await Self.fetch("/players/nfl")
        var index: [String: ResolvedPlayer] = [:]
        index.reserveCapacity(raw.count)
        for (pid, p) in raw {
            let isDef = (p.position ?? "") == "DEF"
            let name: String = {
                if let full = p.fullName?.nilIfBlank { return full }
                let composed = [p.firstName, p.lastName].compactMap { $0?.nilIfBlank }.joined(separator: " ")
                if !composed.isEmpty { return composed }
                if isDef { return "\(p.team ?? pid) DST" }
                return pid
            }()
            let appID: String? = {
                if isDef { return "DEF_\(p.team ?? pid)" }
                return p.gsisId?.nilIfBlank
            }()
            index[pid] = ResolvedPlayer(
                name: name,
                position: p.position ?? "",
                team: p.team ?? "",
                appID: appID
            )
        }
        playerIndex = index
        // The disk write is only for the next launch (in-memory cache is already
        // set), so do it off the actor to not delay the first buildSeason.
        let toSave = index
        Task.detached(priority: .background) { Self.saveIndexToDisk(toSave) }
        return index
    }

    private struct IndexEnvelope: Codable {
        let version: Int
        let savedAt: Date
        let players: [String: ResolvedPlayer]
    }
    private static let indexVersion = 1
    private static let indexTTL: TimeInterval = 24 * 60 * 60

    private static var indexURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sleeper", isDirectory: true)
            .appendingPathComponent("players_v\(indexVersion).plist")
    }

    private static func loadIndexFromDisk() -> [String: ResolvedPlayer]? {
        guard let url = indexURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let env = try PropertyListDecoder().decode(IndexEnvelope.self, from: data)
            guard env.version == indexVersion,
                  Date().timeIntervalSince(env.savedAt) < indexTTL else { return nil }
            return env.players
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func saveIndexToDisk(_ players: [String: ResolvedPlayer]) {
        guard let url = indexURL else { return }
        let env = IndexEnvelope(version: indexVersion, savedAt: Date(), players: players)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(env).write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("SleeperService.saveIndexToDisk failed: \(error)")
            #endif
        }
    }

    // MARK: - Derivations

    private static func scoringLabel(_ settings: [String: Double]?) -> String {
        guard let rec = settings?["rec"] else { return "Standard" }
        if rec >= 1.0 { return "PPR" }
        if rec >= 0.5 { return "Half-PPR" }
        if rec > 0 { return "Custom" }
        return "Standard"
    }

    // The championship match in a winners bracket carries p == 1; its winner is
    // the league champion. Only meaningful once the season has completed.
    private static func champion(from bracket: [SLBracketMatch], leagueComplete: Bool) -> Int? {
        guard leagueComplete, !bracket.isEmpty else { return nil }
        if let championship = bracket.first(where: { $0.p == 1 }), let w = championship.w { return w }
        let maxRound = bracket.compactMap(\.r).max()
        if let maxRound, let m = bracket.first(where: { $0.r == maxRound && $0.w != nil }) { return m.w }
        return nil
    }

    // MARK: - Networking

    private static func fetch<T: Decodable>(_ path: String) async throws -> T {
        let data = try await rawData(path)
        if isNull(data) { throw SleeperError.notFound }
        do {
            return try makeDecoder().decode(T.self, from: data)
        } catch {
            throw SleeperError.decoding(error.localizedDescription)
        }
    }

    // Array endpoint that should never abort the larger import on failure.
    private static func optArray<T: Decodable>(_ path: String) async -> [T] {
        (try? await fetch(path)) ?? []
    }

    private static func rawData(_ path: String) async throws -> Data {
        guard let url = URL(string: base + path) else { throw SleeperError.invalidInput }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw SleeperError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw SleeperError.network("No HTTP response") }
        if http.statusCode == 404 { throw SleeperError.notFound }
        guard (200..<300).contains(http.statusCode) else {
            throw SleeperError.network("HTTP \(http.statusCode)")
        }
        return data
    }

    private static func isNull(_ data: Data) -> Bool {
        let trimmed = data.prefix(8).filter { !($0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09) }
        return trimmed.elementsEqual([0x6e, 0x75, 0x6c, 0x6c]) // "null"
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

enum SleeperError: LocalizedError {
    case invalidInput
    case userNotFound
    case leagueNotFound
    case notFound
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:   return "Enter a Sleeper username or league ID."
        case .userNotFound:   return "No Sleeper user found with that username."
        case .leagueNotFound: return "Couldn't find that Sleeper league. Double-check the league ID."
        case .notFound:       return "Not found."
        case .network(let m): return "Network error: \(m)"
        case .decoding(let m): return "Couldn't read Sleeper's response: \(m)"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Sleeper API DTOs (decoded with convertFromSnakeCase)

private struct SLState: Decodable {
    let season: String
    let week: Int?
    let leg: Int?
}

private struct SLUser: Decodable {
    let userId: String?
    let username: String?
    let displayName: String?
    let avatar: String?
    let metadata: SLUserMetadata?
}
private struct SLUserMetadata: Decodable {
    let teamName: String?
}

private struct SLLeague: Decodable {
    let leagueId: String
    let name: String?
    let season: String?
    let status: String?
    let avatar: String?
    let totalRosters: Int?
    let previousLeagueId: String?
    let rosterPositions: [String]?
    let scoringSettings: [String: Double]?
    let settings: SLLeagueSettings?
}
private struct SLLeagueSettings: Decodable {
    let playoffWeekStart: Int?
    let playoffTeams: Int?
    let numTeams: Int?
}

private struct SLRoster: Decodable {
    let rosterId: Int
    let ownerId: String?
    let players: [String]?
    let starters: [String]?
    let reserve: [String]?
    let taxi: [String]?
    let settings: SLRosterSettings?
}
private struct SLRosterSettings: Decodable {
    let wins: Int?
    let losses: Int?
    let ties: Int?
    let fpts: Int?
    let fptsDecimal: Int?
    let fptsAgainst: Int?
    let fptsAgainstDecimal: Int?
}

private struct SLMatchup: Decodable {
    let rosterId: Int
    let matchupId: Int?
    let points: Double?
}

private struct SLTransaction: Decodable {
    let transactionId: String?
    let type: String?
    let status: String?
    let leg: Int?
    let created: Int?
    let rosterIds: [Int]?
    let adds: [String: Int]?
    let drops: [String: Int]?
    let draftPicks: [SLTxPick]?
    let settings: SLTxSettings?
}
private struct SLTxPick: Decodable {
    let season: String?
    let round: Int?
    let rosterId: Int?
    let previousOwnerId: Int?
    let ownerId: Int?
}
private struct SLTxSettings: Decodable {
    let waiverBid: Int?
}

private struct SLBracketMatch: Decodable {
    let r: Int?
    let m: Int?
    let w: Int?
    let l: Int?
    let p: Int?
}

private struct SLDraft: Decodable {
    let draftId: String
}
private struct SLDraftPick: Decodable {
    let playerId: String?
    let pickedBy: String?
    let rosterId: Int?
    let round: Int?
    let draftSlot: Int?
    let pickNo: Int?
}

private struct SLPlayer: Decodable {
    let fullName: String?
    let firstName: String?
    let lastName: String?
    let position: String?
    let team: String?
    let gsisId: String?
}
