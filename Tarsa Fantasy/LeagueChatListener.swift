import Foundation
import Supabase

// Realtime subscription for one league's chat. Posts an NSNotification for
// each INSERT/DELETE on league_messages and league_message_reactions so the
// LeagueChatView can append/remove rows live without a refresh round-trip.
// Mirrors LiveScoresListener: one channel at a time per app, swapped on
// `start(leagueID:)`.

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
        let messageChanges = ch.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "league_messages",
            filter: .eq("league_id", value: lid)
        )
        // Reactions don't carry league_id directly, so we filter on the
        // client side by joining against the messages we already have.
        // The realtime row only includes message_id + user_id + emoji.
        let reactionChanges = ch.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "league_message_reactions"
        )

        do {
            try await ch.subscribeWithError()
        } catch {
            print("LeagueChatListener subscribe failed: \(error)")
            return
        }
        channel = ch

        Task.detached {
            for await change in messageChanges {
                await Self.routeMessage(change, leagueID: leagueID)
            }
        }
        Task.detached {
            for await change in reactionChanges {
                await Self.routeReaction(change, leagueID: leagueID)
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

    private static func routeMessage(_ change: AnyAction, leagueID: String) async {
        switch change {
        case .insert(let action):
            guard let msg = decodeMessage(action.record) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .leagueChatMessageInserted, object: nil,
                    userInfo: ["leagueID": leagueID, "message": msg]
                )
            }
        case .delete(let action):
            guard let raw = action.oldRecord["id"]?.stringValue,
                  let id  = normalizedUUID(raw) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .leagueChatMessageDeleted, object: nil,
                    userInfo: ["leagueID": leagueID, "id": id]
                )
            }
        case .update:
            // Edits aren't a feature today; nothing to broadcast.
            break
        }
    }

    private static func routeReaction(_ change: AnyAction, leagueID: String) async {
        switch change {
        case .insert(let action):
            guard let reaction = decodeReaction(action.record) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .leagueChatReactionInserted, object: nil,
                    userInfo: ["leagueID": leagueID, "reaction": reaction]
                )
            }
        case .delete(let action):
            guard let reaction = decodeReaction(action.oldRecord) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .leagueChatReactionDeleted, object: nil,
                    userInfo: ["leagueID": leagueID, "reaction": reaction]
                )
            }
        case .update:
            break
        }
    }

    // Decodes the realtime payload into a LeagueMessage (username is nil —
    // the listener doesn't see profiles; the view's local username cache
    // fills in or falls back to "Member"). UUIDs are normalized via
    // `normalizedUUID` so the realtime row's id matches the canonical
    // form returned by sendMessage (Swift's UUID.uuidString is uppercase;
    // Postgres serializes UUIDs as lowercase in JSON, so naive string
    // comparison would dedupe-miss and produce ghost duplicates).
    private static func decodeMessage(_ record: [String: AnyJSON]) -> LeagueMessage? {
        guard
            let idRaw       = record["id"]?.stringValue,
            let leagueRaw   = record["league_id"]?.stringValue,
            let userRaw     = record["user_id"]?.stringValue,
            let content     = record["content"]?.stringValue,
            let createdAt   = record["created_at"]?.stringValue,
            let id          = normalizedUUID(idRaw),
            let leagueID    = normalizedUUID(leagueRaw),
            let userID      = normalizedUUID(userRaw)
        else { return nil }
        let date = Self.iso.date(from: createdAt)
            ?? Self.isoFractional.date(from: createdAt)
            ?? Date()
        let imageURL = record["image_url"]?.stringValue
        return LeagueMessage(
            id: id, leagueID: leagueID, userID: userID,
            username: nil, content: content,
            imageURL: imageURL, createdAt: date
        )
    }

    private static func decodeReaction(_ record: [String: AnyJSON]) -> LeagueMessageReaction? {
        guard
            let msgRaw  = record["message_id"]?.stringValue,
            let userRaw = record["user_id"]?.stringValue,
            let emoji   = record["emoji"]?.stringValue,
            let msgID   = normalizedUUID(msgRaw),
            let userID  = normalizedUUID(userRaw)
        else { return nil }
        return LeagueMessageReaction(messageID: msgID, userID: userID, emoji: emoji)
    }

    // Canonicalizes a UUID string to Swift's uppercase form. Returns nil
    // if the string isn't a valid UUID.
    private static func normalizedUUID(_ s: String) -> String? {
        UUID(uuidString: s)?.uuidString
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
    static let leagueChatMessageInserted  = Notification.Name("leagueChatMessageInserted")
    static let leagueChatMessageDeleted   = Notification.Name("leagueChatMessageDeleted")
    static let leagueChatReactionInserted = Notification.Name("leagueChatReactionInserted")
    static let leagueChatReactionDeleted  = Notification.Name("leagueChatReactionDeleted")
}

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
