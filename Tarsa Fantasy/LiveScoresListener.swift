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
        // Full stat line: raw counting stats ride along with the preset
        // points so custom-scoring leagues and K/DST score correctly live.
        func num(_ key: String) -> Double { record[key]?.doubleValue ?? 0 }
        var line = NFLDataService.LiveStatLine()
        line.standard = num("fantasy_points")
        line.ppr      = num("fantasy_points_ppr")
        line.halfPpr  = num("fantasy_points_half_ppr")
        line.isFinal  = record["is_final"]?.boolValue ?? false
        line.completions          = num("completions")
        line.attempts             = num("attempts")
        line.passingYards         = num("passing_yards")
        line.passingTDs           = num("passing_tds")
        line.passingInterceptions = num("passing_interceptions")
        line.carries              = num("carries")
        line.rushingYards         = num("rushing_yards")
        line.rushingTDs           = num("rushing_tds")
        line.receptions           = num("receptions")
        line.targets              = num("targets")
        line.receivingYards       = num("receiving_yards")
        line.receivingTDs         = num("receiving_tds")
        line.fumblesLost          = num("fumbles_lost")
        line.fieldGoals0_19       = num("fg_made_0_19")
        line.fieldGoals20_29      = num("fg_made_20_29")
        line.fieldGoals30_39      = num("fg_made_30_39")
        line.fieldGoals40_49      = num("fg_made_40_49")
        line.fieldGoals50_59      = num("fg_made_50_59")
        line.fieldGoals60Plus     = num("fg_made_60")
        line.fieldGoalsMissed     = num("fg_missed")
        line.extraPointsMade      = num("pat_made")
        line.extraPointsMissed    = num("pat_missed")
        line.defSacks             = num("def_sacks")
        line.defInterceptions     = num("def_interceptions")
        line.defFumbleRecoveries  = num("def_fumble_recoveries")
        line.defTouchdowns        = num("def_tds")
        line.defSafeties          = num("def_safeties")
        line.pointsAllowed        = record["def_points_allowed"]?.doubleValue
        await NFLDataService.shared.applyLiveOverride(
            playerID: pid, season: season, week: week, line: line
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
