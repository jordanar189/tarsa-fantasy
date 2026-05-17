import Foundation

// Persistent on-disk snapshot of [String: Player] per season. The whole point
// is to make cold-launch instant: AppState reads from here synchronously
// before any UI renders, then kicks off a background refresh from Supabase
// and swaps the in-memory dict when fresh data arrives.
//
// Format: binary property list. Faster to decode than JSON for our shape
// (deeply nested numeric arrays) and built into Foundation, no deps.
//
// Envelope carries a version so future model changes invalidate old caches
// gracefully — bump VERSION when adding/removing fields on Player or Game.
struct PlayerCacheStore {
    static let shared = PlayerCacheStore()

    // Bump when Player / Game / PlayerProfile shape changes so old caches
    // discard cleanly. V2 adds the optional PlayerProfile field.
    private static let version = 2

    private struct Envelope: Codable {
        let version: Int
        let savedAt: Date
        let season: Int
        let players: [String: Player]
    }

    // Location of the cache directory; nil only if we somehow can't get a
    // Caches directory, which shouldn't happen on iOS.
    private var directory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("player_cache", isDirectory: true)
    }

    private func url(for season: Int) -> URL? {
        directory?.appendingPathComponent("season_\(season)_v\(Self.version).plist")
    }

    // MARK: - Read

    // Synchronous on purpose — caller invokes this on the MainActor at app
    // launch and needs the dict before rendering anything. ~5-10 MB binary
    // plist reads in single-digit ms on modern devices.
    func loadSync(season: Int) -> [String: Player]? {
        guard let url = url(for: season),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Self.version, envelope.season == season else { return nil }
            return envelope.players
        } catch {
            // Corrupt or schema-mismatched file — drop it so we don't keep
            // hitting the same decode error on every launch.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // How old the cached snapshot is, or nil if no cache exists. Used by the
    // refresh policy if we ever want to gate background refresh on staleness.
    func ageSync(season: Int) -> TimeInterval? {
        guard let url = url(for: season),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    // MARK: - Write

    // Fire-and-forget. Encoding 3K players + 50K games takes a couple hundred
    // ms; we run it off the main thread to keep the UI smooth.
    func save(season: Int, players: [String: Player]) {
        guard let directory, let url = url(for: season) else { return }
        let envelope = Envelope(
            version: Self.version, savedAt: Date(),
            season: season, players: players
        )
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(envelope)
                // .atomic = write to temp + rename, so a crash mid-write
                // doesn't leave a half-written file the next launch reads.
                try data.write(to: url, options: .atomic)
            } catch {
                // Disk-full or sandbox quirks — no recovery path; just skip.
                // Next successful fetch will try again.
                #if DEBUG
                print("PlayerCacheStore.save(\(season)) failed: \(error)")
                #endif
            }
        }
    }

    // Bulk wipe (e.g., user signs out + signs in as someone else; tests).
    func clearAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
