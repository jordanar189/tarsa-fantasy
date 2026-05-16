import Foundation
import Security

// File-backed CRUD for fantasy leagues. Persists to a single JSON file in the
// app's Documents directory so leagues survive app launches.
actor LeagueStore {

    static let shared = LeagueStore()

    private let url: URL
    private var leagues: [String: League] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(filename: String = "leagues.json") {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent(filename)
        self.url = fileURL

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        // Inline load so we don't call an actor-isolated method from init.
        if let data = try? Data(contentsOf: fileURL),
           let envelope = try? dec.decode(Envelope.self, from: data) {
            self.leagues = Dictionary(uniqueKeysWithValues: envelope.leagues.map { ($0.id, $0) })
        }
    }

    private struct Envelope: Codable { var leagues: [League] }

    private func save() throws {
        let envelope = Envelope(leagues: Array(leagues.values))
        let data = try encoder.encode(envelope)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    func list() -> [LeagueSummary] {
        leagues.values
            .sorted { $0.createdAt > $1.createdAt }
            .map { LeagueSummary(
                id: $0.id, name: $0.name, season: $0.season,
                scoring: $0.scoring, teamCount: $0.teams.count,
                createdAt: $0.createdAt
            ) }
    }

    func get(_ id: String) -> League? { leagues[id] }

    @discardableResult
    func create(
        name: String, season: Int, scoring: Scoring,
        teamNames: [String], rosterConfig: RosterConfig = .default
    ) throws -> League {
        let cleanedName = name.trimmingCharacters(in: .whitespaces)
        let cleanedTeams = teamNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard cleanedTeams.count >= 2 else { throw StoreError.tooFewTeams }
        guard cleanedTeams.count <= 16 else { throw StoreError.tooManyTeams }

        let teams = cleanedTeams.map { FantasyTeam(id: Self.newID(), name: $0, roster: []) }
        let league = League(
            id: Self.newID(),
            name: cleanedName.isEmpty ? "Untitled League" : cleanedName,
            season: season,
            scoring: scoring,
            createdAt: Date(),
            teams: teams,
            schedule: Fantasy.generateSchedule(teamIDs: teams.map(\.id)),
            rosterConfig: rosterConfig
        )
        leagues[league.id] = league
        try save()
        return league
    }

    // `starters` should be the auto-fill result computed by the caller (which
    // has access to player season points). Length must match the league's
    // starterCount; pass [] to leave the lineup unset.
    @discardableResult
    func setRoster(
        leagueID: String, teamID: String,
        playerIDs: [String], starters: [String] = []
    ) throws -> League {
        guard var league = leagues[leagueID] else { throw StoreError.leagueNotFound }
        guard let idx = league.teams.firstIndex(where: { $0.id == teamID }) else {
            throw StoreError.teamNotFound
        }
        var seen: Set<String> = []
        var roster: [String] = []
        for pid in playerIDs where !pid.isEmpty && !seen.contains(pid) {
            seen.insert(pid)
            roster.append(pid)
        }
        let starterCount = league.rosterConfig.starterCount
        let lineup: [String]
        if starters.count == starterCount {
            let onRoster = Set(roster)
            lineup = starters.map { onRoster.contains($0) ? $0 : "" }
        } else {
            lineup = []
        }
        league.teams[idx].roster = roster
        league.teams[idx].starters = lineup
        leagues[leagueID] = league
        try save()
        return league
    }

    @discardableResult
    func delete(_ id: String) throws -> Bool {
        let existed = leagues.removeValue(forKey: id) != nil
        if existed { try save() }
        return existed
    }

    private static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    enum StoreError: LocalizedError {
        case tooFewTeams, tooManyTeams, leagueNotFound, teamNotFound
        var errorDescription: String? {
            switch self {
            case .tooFewTeams:    return "A league needs at least 2 teams."
            case .tooManyTeams:   return "A league can have at most 16 teams."
            case .leagueNotFound: return "League not found."
            case .teamNotFound:   return "Team not found."
            }
        }
    }
}
