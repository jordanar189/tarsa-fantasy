import Foundation
import Supabase

// Shared plumbing for the Realtime listeners. Two failure modes were
// previously unhandled: a failed subscribe left the listener dead for the
// whole session (one print, no retry), and events delivered while the app
// was backgrounded were silently lost (delta streams have no replay). Every
// listener now subscribes through the retry helper and registers a
// foreground hook that re-establishes the channel and triggers a full
// catch-up fetch.

enum RealtimeResilience {

    /// Subscribe with exponential backoff. Returns true once subscribed.
    static func subscribe(_ channel: RealtimeChannelV2, label: String, attempts: Int = 5) async -> Bool {
        var delay: UInt64 = 1_000_000_000
        for attempt in 1...attempts {
            do {
                try await channel.subscribeWithError()
                return true
            } catch {
                print("\(label): subscribe attempt \(attempt)/\(attempts) failed: \(error)")
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, 16_000_000_000)
                }
            }
        }
        return false
    }
}

extension Notification.Name {
    // Posted by listeners after a foreground catch-up: consumers holding
    // incrementally-built state (chat transcripts, draft boards) should
    // re-fetch from the source of truth — deltas may have been missed.
    static let leagueChatResync = Notification.Name("leagueChatResync")
    static let dmChatResync     = Notification.Name("dmChatResync")
}
