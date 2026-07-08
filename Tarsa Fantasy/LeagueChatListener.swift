import Foundation
import Supabase
import UIKit

// Realtime subscription for one league's chat. Posts an NSNotification for
// each INSERT/DELETE on league_messages and league_message_reactions so the
// LeagueChatView can append/remove rows live without a refresh round-trip.
// Mirrors LiveScoresListener: one channel at a time per app, swapped on
// `start(leagueID:)`. Subscribes with retry; on app-foreground it
// re-establishes a dead channel and posts .leagueChatResync so the view
// reloads the transcript (deltas delivered while backgrounded are lost).

actor LeagueChatListener {
    static let shared = LeagueChatListener()

    private var channel: RealtimeChannelV2?
    private var currentLeagueID: String?
    private var foregroundObserver: (any NSObjectProtocol)?

    func start(leagueID: String) async {
        if currentLeagueID == leagueID, channel != nil { return }
        await stop()
        guard let lid = UUID(uuidString: leagueID) else { return }
        currentLeagueID = leagueID
        installForegroundHook()

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
        // Structured-message responses (poll/pick'em votes). Like reactions,
        // these don't carry league_id; the view filters by loaded messages.
        let responseChanges = ch.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "message_responses"
        )

        guard await RealtimeResilience.subscribe(ch, label: "LeagueChatListener") else {
            // Foreground hook retries; currentLeagueID stays set for it.
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
        Task.detached {
            for await change in responseChanges {
                await Self.routeResponse(change, leagueID: leagueID)
            }
        }
    }

    func stop() async {
        if let ch = channel {
            await ch.unsubscribe()
        }
        channel = nil
        currentLeagueID = nil
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
            Task { await LeagueChatListener.shared.foregroundResync() }
        }
    }

    private func foregroundResync() async {
        guard let leagueID = currentLeagueID else { return }
        if channel == nil {
            currentLeagueID = nil   // force start() past its idempotence guard
            await start(leagueID: leagueID)
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .leagueChatResync, object: nil, userInfo: ["leagueID": leagueID])
        }
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
        case .update(let action):
            // Payload edits (e.g. a member adding a poll option) arrive as
            // UPDATEs — rebroadcast so every client refreshes the card.
            guard let msg = decodeMessage(action.record) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .leagueChatMessageUpdated, object: nil,
                    userInfo: ["leagueID": leagueID, "message": msg]
                )
            }
        }
    }

    // Upserts arrive as INSERT or UPDATE; both map to "this user's vote is now
    // X". DELETE removes the vote.
    private static func routeResponse(_ change: AnyAction, leagueID: String) async {
        switch change {
        case .insert(let action):
            guard let response = decodeResponse(action.record) else { return }
            await postResponseChanged(response, leagueID: leagueID)
        case .update(let action):
            guard let response = decodeResponse(action.record) else { return }
            await postResponseChanged(response, leagueID: leagueID)
        case .delete(let action):
            guard let response = decodeResponse(action.oldRecord) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .leagueChatResponseDeleted, object: nil,
                    userInfo: ["leagueID": leagueID, "response": response]
                )
            }
        }
    }

    private static func postResponseChanged(_ response: MessageResponse, leagueID: String) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .leagueChatResponseChanged, object: nil,
                userInfo: ["leagueID": leagueID, "response": response]
            )
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
        let kind = MessageKind(rawValue: record["message_type"]?.stringValue ?? "text") ?? .text
        let payload = decodePayload(record["payload"])
        return LeagueMessage(
            id: id, leagueID: leagueID, userID: userID,
            username: nil, content: content,
            imageURL: imageURL, createdAt: date,
            kind: kind, payload: payload
        )
    }

    // Decodes the realtime jsonb payload into a strongly-typed ChatPayload.
    // Realtime usually delivers jsonb as a nested object, but some setups send
    // it as a JSON string — handle both.
    private static func decodePayload(_ json: AnyJSON?) -> ChatPayload? {
        guard let json else { return nil }
        switch json {
        case .null:
            return nil
        case .string(let s):
            guard let data = s.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ChatPayload.self, from: data)
        default:
            guard let data = try? JSONEncoder().encode(json) else { return nil }
            return try? JSONDecoder().decode(ChatPayload.self, from: data)
        }
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

    private static func decodeResponse(_ record: [String: AnyJSON]) -> MessageResponse? {
        guard
            let msgRaw  = record["message_id"]?.stringValue,
            let userRaw = record["user_id"]?.stringValue,
            let msgID   = normalizedUUID(msgRaw),
            let userID  = normalizedUUID(userRaw)
        else { return nil }
        // `slot` is part of the primary key, so it's present on every event
        // (including DELETE old records). `choice` is absent on DELETE; the
        // delete handler ignores it, so default to 0.
        let slot   = record["slot"]?.intValue ?? 0
        let choice = record["choice"]?.intValue ?? 0
        return MessageResponse(messageID: msgID, userID: userID, slot: slot, choice: choice)
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
    static let leagueChatMessageUpdated   = Notification.Name("leagueChatMessageUpdated")
    static let leagueChatMessageDeleted   = Notification.Name("leagueChatMessageDeleted")
    static let leagueChatReactionInserted = Notification.Name("leagueChatReactionInserted")
    static let leagueChatReactionDeleted  = Notification.Name("leagueChatReactionDeleted")
    static let leagueChatResponseChanged  = Notification.Name("leagueChatResponseChanged")
    static let leagueChatResponseDeleted  = Notification.Name("leagueChatResponseDeleted")
}

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .double(let d):  return Int(d)
        case .string(let s):  return Int(s)
        default:              return nil
        }
    }
}
