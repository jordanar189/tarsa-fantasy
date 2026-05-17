import Foundation
import Supabase

// Realtime subscription for one league's chat. Posts an NSNotification for
// each INSERT/DELETE so the LeagueChatView can append/remove messages live
// without a refresh round-trip. Mirrors LiveScoresListener: one channel at
// a time per app, swapped on `start(leagueID:)`.

actor LeagueChatListener {
    static let shared = LeagueChatListener()

    private var channel: RealtimeChannelV2?
    private var currentLeagueID: String?

    func start(leagueID: String) async {
        if currentLeagueID == leagueID, channel != nil { return }
        await stop()
        guard let lid = UUID(uuidString: leagueID) else { return }
        currentLeagueID = leagueID

        let client = SupabaseConfig.sharedClient
        let ch = client.channel("league-chat-\(leagueID)")
        let changes = ch.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "league_messages",
            filter: .eq("league_id", value: lid)
        )

        do {
            try await ch.subscribeWithError()
        } catch {
            print("LeagueChatListener subscribe failed: \(error)")
            return
        }
        channel = ch

        Task.detached {
            for await change in changes {
                await Self.route(change, leagueID: leagueID)
            }
        }
    }

    func stop() async {
        if let ch = channel {
            await ch.unsubscribe()
        }
        channel = nil
        currentLeagueID = nil
    }

    private static func route(_ change: AnyAction, leagueID: String) async {
        switch change {
        case .insert(let action):
            guard let msg = decode(action.record) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .leagueChatMessageInserted, object: nil,
                    userInfo: ["leagueID": leagueID, "message": msg]
                )
            }
        case .delete(let action):
            guard let oldID = action.oldRecord["id"]?.stringValue else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .leagueChatMessageDeleted, object: nil,
                    userInfo: ["leagueID": leagueID, "id": oldID]
                )
            }
        case .update:
            // Edits aren't a feature today; nothing to broadcast.
            break
        }
    }

    // Decodes the realtime payload into a LeagueMessage (username is nil —
    // the listener doesn't see profiles; the view's local username cache
    // fills in or falls back to "Member").
    private static func decode(_ record: [String: AnyJSON]) -> LeagueMessage? {
        guard
            let id        = record["id"]?.stringValue,
            let leagueID  = record["league_id"]?.stringValue,
            let userID    = record["user_id"]?.stringValue,
            let content   = record["content"]?.stringValue,
            let createdAt = record["created_at"]?.stringValue
        else { return nil }
        let date = Self.iso.date(from: createdAt)
            ?? Self.isoFractional.date(from: createdAt)
            ?? Date()
        return LeagueMessage(
            id: id, leagueID: leagueID, userID: userID,
            username: nil, content: content, createdAt: date
        )
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension Notification.Name {
    static let leagueChatMessageInserted = Notification.Name("leagueChatMessageInserted")
    static let leagueChatMessageDeleted  = Notification.Name("leagueChatMessageDeleted")
}

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
