import Foundation
import Supabase
import UIKit

// Subscribes to the `preseason:<season>` Realtime BROADCAST topic. The
// sync_espn_preseason edge function sends one `preseason_updated` message per
// run (payload: season, pre_week, game_ids) instead of per-row
// postgres_changes, so the server cost stays flat however many phones are
// watching; consumers re-fetch what they are showing. One listener at a time
// (start(season:) again replaces it). Like the other listeners, a foreground
// re-establishes a dead channel and posts a catch-up notification, because
// messages delivered while backgrounded are lost.
actor PreseasonListener {
    static let shared = PreseasonListener()

    private var channel: RealtimeChannelV2?
    private var currentSeason: Int?
    private var foregroundObserver: (any NSObjectProtocol)?

    func start(season: Int) async {
        if currentSeason == season, channel != nil { return }
        await stop()
        currentSeason = season
        installForegroundHook()

        let client = SupabaseConfig.sharedClient
        let ch = client.channel("preseason:\(season)")
        let messages = ch.broadcastStream(event: "preseason_updated")

        guard await RealtimeResilience.subscribe(ch, label: "PreseasonListener") else {
            return   // foreground hook retries; currentSeason stays set for it
        }
        channel = ch

        Task.detached {
            for await message in messages {
                // realtime.send() wraps what we sent: {event, payload: {...}, type}.
                let body = message["payload"]?.objectValue ?? message
                let gameIDs = body["game_ids"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                await Self.post(season: season, gameIDs: gameIDs)
            }
        }
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

    private func installForegroundHook() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            Task {
                guard let season = await PreseasonListener.shared.currentSeasonValue else { return }
                if await PreseasonListener.shared.channelIsDead {
                    await PreseasonListener.shared.restart(season: season)
                }
                // Empty game list = "refetch whatever you're showing".
                await PreseasonListener.post(season: season, gameIDs: [])
            }
        }
    }

    private var currentSeasonValue: Int? { currentSeason }
    private var channelIsDead: Bool { channel == nil }
    private func restart(season: Int) async {
        currentSeason = nil   // force start() past its idempotence guard
        await start(season: season)
    }

    private static func post(season: Int, gameIDs: [String]) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .preseasonUpdated, object: nil,
                userInfo: ["season": season, "gameIDs": gameIDs]
            )
        }
    }
}

extension Notification.Name {
    // userInfo: "season": Int, "gameIDs": [String] (empty = refetch everything).
    static let preseasonUpdated = Notification.Name("preseasonUpdated")
}

private extension AnyJSON {
    var objectValue: [String: AnyJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }
    var arrayValue: [AnyJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
