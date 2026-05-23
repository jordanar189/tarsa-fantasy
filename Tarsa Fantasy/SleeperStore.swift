import Foundation

// On-disk persistence for leagues imported from Sleeper. These are user data
// (not a regenerable cache), so they live in Application Support rather than
// Caches. A single JSON envelope holds every imported league; AppState keeps
// the in-memory copy and writes the whole list back on add/remove.
struct SleeperStore {
    static let shared = SleeperStore()

    private static let version = 1

    private struct Envelope: Codable {
        let version: Int
        let leagues: [ImportedLeague]
    }

    private var fileURL: URL? {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("sleeper", isDirectory: true)
        return dir.appendingPathComponent("imported_leagues_v\(Self.version).json")
    }

    func loadAll() -> [ImportedLeague] {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let env = try JSONDecoder.sleeperStore.decode(Envelope.self, from: data)
            guard env.version == Self.version else { return [] }
            return env.leagues
        } catch {
            return []
        }
    }

    func saveAll(_ leagues: [ImportedLeague]) {
        guard let url = fileURL else { return }
        let env = Envelope(version: Self.version, leagues: leagues)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder.sleeperStore.encode(env)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("SleeperStore.saveAll failed: \(error)")
            #endif
        }
    }
}

private extension JSONDecoder {
    static let sleeperStore: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let sleeperStore: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
