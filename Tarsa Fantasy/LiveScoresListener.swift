import Foundation
import Supabase
import UIKit

// Subscribes to the `live_scores` Supabase Realtime channel and routes each
// INSERT/UPDATE/DELETE into NFLDataService.applyLiveOverride. Only one
// listener is active at a time; calling `start(season:)` again replaces the
// previous one. Subscribes with retry, and on every app-foreground both
// re-establishes a dead channel and re-fetches the full live snapshot —
// realtime deltas delivered while backgrounded are lost, and a mid-game
// scoreboard that silently stops updating is the worst failure mode here.

actor LiveScoresListener {
    static let shared = LiveScoresListener()

    private var channel: RealtimeChannelV2?
    private var currentSeason: Int?
    private var foregroundObserver: (any NSObjectProtocol)?

    func start(season: Int) async {
        if currentSeason == season, channel != nil { return }
        await stop()
        currentSeason = season
        installForegroundHook()

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
        guard await RealtimeResilience.subscribe(ch, label: "LiveScoresListener") else {
            // The foreground hook retries; currentSeason stays set so the
            // retry knows what to restart.
            return
        }
        channel = ch

        Task.detached {
            for await change in changes {
                await Self.routeChange(change)
            }
        }

        // Catch up on anything that landed between the last fetch and the
        // subscription going live.
        await resync()
    }

    func stop() async {
        if let ch = channel {
            await ch.unsubscribe()
        }
        channel = nil
        currentSeason = nil
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
    }

    // Full snapshot fetch of the season's live rows — the catch-up for any
    // deltas missed while backgrounded or between subscribe attempts.
    func resync() async {
        guard let season = currentSeason else { return }
        let client = SupabaseConfig.sharedClient
        var from = 0
        let page = 1000
        var any = false
        while true {
            guard let rows: [[String: AnyJSON]] = try? await client.from("live_scores")
                .select()
                .eq("season", value: season)
                .order("player_id")
                .range(from: from, to: from + page - 1)
                .execute().value
            else { break }
            for record in rows { await Self.applyRecord(record, notify: false) }
            any = any || !rows.isEmpty
            if rows.count < page { break }
            from += page
        }
        if any {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .liveScoresUpdated, object: nil, userInfo: ["season": season]
                )
            }
        }
    }

    private func installForegroundHook() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            Task {
                // Re-establish a dead channel, then catch up.
                if let season = await LiveScoresListener.shared.currentSeasonValue,
                   await LiveScoresListener.shared.channelIsDead {
                    await LiveScoresListener.shared.restart(season: season)
                } else {
                    await LiveScoresListener.shared.resync()
                }
            }
        }
    }

    private var currentSeasonValue: Int? { currentSeason }
    private var channelIsDead: Bool { channel == nil }
    private func restart(season: Int) async {
        currentSeason = nil   // force start() past its idempotence guard
        await start(season: season)
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

    private static func applyRecord(_ record: [String: AnyJSON], notify: Bool = true) async {
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
        line.defTacklesSolo       = num("def_tackles_solo")
        line.defTackleAssists     = num("def_tackle_assists")
        line.defTacklesForLoss    = num("def_tackles_for_loss")
        line.defQbHits            = num("def_qb_hits")
        line.defPassesDefended    = num("def_pass_defended")
        line.defFumblesForced     = num("def_fumbles_forced")
        line.pointsAllowed        = record["def_points_allowed"]?.doubleValue
        await NFLDataService.shared.applyLiveOverride(
            playerID: pid, season: season, week: week, line: line
        )
        // Tell anyone observing (AppState) that this season's snapshot is
        // dirty. Suppressed during resync's bulk apply — it posts once at the
        // end instead of once per row.
        guard notify else { return }
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
