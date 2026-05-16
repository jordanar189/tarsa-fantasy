import Foundation

// Downloads nflverse weekly player stats CSVs and parses them into Players.
// Caches the raw CSV on disk for a few hours and the parsed result in memory.
actor NFLDataService {

    static let shared = NFLDataService()

    private let session: URLSession
    private let cacheDir: URL
    private let ttl: TimeInterval = 6 * 60 * 60
    private let dataURLTemplate =
        "https://github.com/nflverse/nflverse-data/releases/download/player_stats/stats_player_week_%d.csv"

    private var parsed: [Int: [String: Player]] = [:]
    private var seasons: [Int]? = nil

    init(session: URLSession = .shared) {
        self.session = session
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDir = caches.appendingPathComponent("nflverse", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func cachePath(for season: Int) -> URL {
        cacheDir.appendingPathComponent("stats_player_week_\(season).csv")
    }

    private func sourceURL(for season: Int) -> URL {
        URL(string: String(format: dataURLTemplate, season))!
    }

    func players(season: Int) async throws -> [String: Player] {
        if let cached = parsed[season] { return cached }
        let csv = try await fetchCSV(season: season)
        let players = parsePlayerStats(csv)
        parsed[season] = players
        return players
    }

    func defaultSeason() async -> Int {
        let list = await availableSeasons()
        return list.first ?? Calendar.current.component(.year, from: Date())
    }

    // Probes nflverse for which season files exist. Cached after first call.
    func availableSeasons() async -> [Int] {
        if let seasons = seasons { return seasons }
        let currentYear = Calendar.current.component(.year, from: Date())
        var found: [Int] = []
        for season in stride(from: currentYear, through: 2016, by: -1) {
            if FileManager.default.fileExists(atPath: cachePath(for: season).path) {
                found.append(season)
                continue
            }
            var req = URLRequest(url: sourceURL(for: season))
            req.httpMethod = "HEAD"
            req.timeoutInterval = 15
            req.setValue("fantasy-football-ios", forHTTPHeaderField: "User-Agent")
            do {
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    found.append(season)
                }
            } catch {
                continue
            }
        }
        seasons = found
        return found
    }

    private func fetchCSV(season: Int) async throws -> String {
        let path = cachePath(for: season)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < ttl {
            return try String(contentsOf: path, encoding: .utf8)
        }
        var req = URLRequest(url: sourceURL(for: season))
        req.timeoutInterval = 60
        req.setValue("fantasy-football-ios", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw DataError.upstream(status: http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DataError.decode
        }
        try? text.write(to: path, atomically: true, encoding: .utf8)
        return text
    }

    enum DataError: LocalizedError {
        case upstream(status: Int)
        case decode
        var errorDescription: String? {
            switch self {
            case .upstream(let s): return "nflverse returned HTTP \(s)"
            case .decode:          return "couldn't decode nflverse response"
            }
        }
    }
}

// MARK: - CSV parsing

func parsePlayerStats(_ csvText: String) -> [String: Player] {
    let rows = CSVParser.parse(csvText)
    guard let header = rows.first else { return [:] }
    let idx = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
    func g(_ row: [String], _ key: String) -> String? {
        guard let i = idx[key], i < row.count else { return nil }
        return row[i]
    }
    func n(_ row: [String], _ key: String) -> Double { num(g(row, key)) }

    var players: [String: Player] = [:]
    for row in rows.dropFirst() {
        if row.allSatisfy({ $0.isEmpty }) { continue }
        if (g(row, "season_type") ?? "").uppercased() != "REG" { continue }
        guard let pid = g(row, "player_id"), !pid.isEmpty else { continue }

        if players[pid] == nil {
            let displayName: String = g(row, "player_display_name") ?? g(row, "player_name") ?? pid
            let position: String = g(row, "position") ?? ""
            let positionGroup: String = g(row, "position_group") ?? ""
            let headshot: String = g(row, "headshot_url") ?? ""
            let team: String = g(row, "team") ?? ""
            players[pid] = Player(
                id: pid,
                name: displayName,
                position: position,
                positionGroup: positionGroup,
                headshotURL: headshot,
                team: team,
                games: []
            )
        }
        if let team = g(row, "team"), !team.isEmpty {
            players[pid]!.team = team
        }

        let gameTeam: String = g(row, "team") ?? ""
        let gameOpponent: String = g(row, "opponent_team") ?? ""
        var game = Game(
            season: Int(n(row, "season")),
            week: Int(n(row, "week")),
            team: gameTeam,
            opponent: gameOpponent
        )
        game.completions          = n(row, "completions")
        game.attempts             = n(row, "attempts")
        game.passingYards         = n(row, "passing_yards")
        game.passingTDs           = n(row, "passing_tds")
        game.passingInterceptions = n(row, "passing_interceptions")
        game.carries              = n(row, "carries")
        game.rushingYards         = n(row, "rushing_yards")
        game.rushingTDs           = n(row, "rushing_tds")
        game.receptions           = n(row, "receptions")
        game.targets              = n(row, "targets")
        game.receivingYards       = n(row, "receiving_yards")
        game.receivingTDs         = n(row, "receiving_tds")
        game.fumblesLost = n(row, "sack_fumbles_lost") + n(row, "rushing_fumbles_lost") + n(row, "receiving_fumbles_lost")
        game.fantasyPoints        = n(row, "fantasy_points")
        game.fantasyPointsPPR     = n(row, "fantasy_points_ppr")
        game.fantasyPointsHalfPPR = Fantasy.round2(game.fantasyPoints + 0.5 * game.receptions)

        players[pid]!.games.append(game)
    }
    for pid in players.keys {
        players[pid]!.games.sort { $0.week < $1.week }
    }
    return players
}

private func num(_ value: String?) -> Double {
    guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return 0 }
    let upper = raw.uppercased()
    if upper == "NA" || upper == "NAN" || upper == "NULL" { return 0 }
    return Double(raw) ?? 0
}

// Minimal RFC 4180 CSV parser — handles quoted fields with embedded commas
// and newlines, and "" for an escaped quote inside a quoted field.
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        i = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field); field = ""
                case "\r":
                    break // handled by \n
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default:
                    field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
