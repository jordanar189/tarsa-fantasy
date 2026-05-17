import Foundation
import Supabase

// Subscribes to the `live_scores` Supabase Realtime channel and routes each
// INSERT/UPDATE/DELETE into NFLDataService.applyLiveOverride. Only one
// listener is active at a time; calling `start(season:)` again replaces the
// previous one.

actor LiveScoresListener {
    static let shared = LiveScoresListener()

    private var channel: RealtimeChannelV2?
    private var currentSeason: Int?

    func start(season: Int) async {
        if currentSeason == season, channel != nil { return }
        await stop()
        currentSeason = season

        let client = SupabaseConfig.sharedClient
        let ch = client.channel("live-scores-\(season)")

        let changes = ch.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "live_scores",
            filter: .eq("season", value: season)
        )

        // The subscription must be active before the changes-stream begins
        // delivering events, so subscribe first then iterate.
        do {
            try await ch.subscribeWithError()
        } catch {
            print("LiveScoresListener subscribe failed: \(error)")
            return
        }
        channel = ch

        Task.detached {
            for await change in changes {
                await Self.routeChange(change)
            }
        }
    }

    func stop() async {
        if let ch = channel {
            await ch.unsubscribe()
        }
        channel = nil
        currentSeason = nil
    }

    private static func routeChange(_ change: AnyAction) async {
        switch change {
        case .insert(let action):
            await applyRecord(action.record)
        case .update(let action):
            await applyRecord(action.record)
        case .delete:
            // Live override cleared (game ended → finalized into player_games).
            // Cached `Game` keeps its stored points on next read; nothing to do here.
            break
        }
    }

    private static func applyRecord(_ record: [String: AnyJSON]) async {
        guard
            let pid    = record["player_id"]?.stringValue,
            let season = record["season"]?.intValue,
            let week   = record["week"]?.intValue
        else { return }
        let std  = record["fantasy_points"]?.doubleValue          ?? 0
        let ppr  = record["fantasy_points_ppr"]?.doubleValue      ?? 0
        let half = record["fantasy_points_half_ppr"]?.doubleValue ?? 0
        let final = record["is_final"]?.boolValue ?? false
        await NFLDataService.shared.applyLiveOverride(
            playerID: pid, season: season, week: week,
            standard: std, ppr: ppr, halfPpr: half, isFinal: final
        )
        // Tell anyone observing (AppState) that this season's snapshot is dirty.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .liveScoresUpdated,
                object: nil,
                userInfo: ["season": season]
            )
        }
    }
}

extension Notification.Name {
    static let liveScoresUpdated = Notification.Name("liveScoresUpdated")
}

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var intValue: Int? {
        if case .integer(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .integer(let i) = self { return Double(i) }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
