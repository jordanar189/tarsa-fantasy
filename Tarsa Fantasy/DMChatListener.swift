import Foundation
import Supabase

// Realtime subscription for one DM thread. Mirrors LeagueChatListener:
// posts NSNotifications on INSERT/DELETE so the open DMChatView appends
// or removes messages live. One channel at a time per app, swapped on
// `start(threadID:)`.

actor DMChatListener {
    static let shared = DMChatListener()

    private var channel: RealtimeChannelV2?
    private var currentThreadID: String?

    func start(threadID: String) async {
        if currentThreadID == threadID, channel != nil { return }
        await stop()
        guard let tid = UUID(uuidString: threadID) else { return }
        currentThreadID = threadID

        let client = SupabaseConfig.sharedClient
        let ch = client.channel("dm-thread-\(threadID)")
        let changes = ch.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "dm_messages",
            filter: .eq("thread_id", value: tid)
        )

        do {
            try await ch.subscribeWithError()
        } catch {
            print("DMChatListener subscribe failed: \(error)")
            return
        }
        channel = ch

        Task.detached {
            for await change in changes {
                await Self.route(change, threadID: threadID)
            }
        }
    }

    func stop() async {
        if let ch = channel {
            await ch.unsubscribe()
        }
        channel = nil
        currentThreadID = nil
    }

    private static func route(_ change: AnyAction, threadID: String) async {
        switch change {
        case .insert(let action):
            guard let msg = decode(action.record) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .dmMessageInserted, object: nil,
                    userInfo: ["threadID": threadID, "message": msg]
                )
            }
        case .delete(let action):
            guard let raw = action.oldRecord["id"]?.stringValue,
                  let id  = UUID(uuidString: raw)?.uuidString else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .dmMessageDeleted, object: nil,
                    userInfo: ["threadID": threadID, "id": id]
                )
            }
        case .update:
            break
        }
    }

    // Canonicalize UUIDs to Swift's uppercase form so the DMChatView's
    // dedupe by id (and isMine comparison) match the values returned by
    // sendDMMessage. Same fix as LeagueChatListener.
    private static func decode(_ record: [String: AnyJSON]) -> DMMessage? {
        guard
            let idRaw       = record["id"]?.stringValue,
            let threadRaw   = record["thread_id"]?.stringValue,
            let senderRaw   = record["sender_id"]?.stringValue,
            let content     = record["content"]?.stringValue,
            let createdAt   = record["created_at"]?.stringValue,
            let id          = UUID(uuidString: idRaw)?.uuidString,
            let threadID    = UUID(uuidString: threadRaw)?.uuidString,
            let senderID    = UUID(uuidString: senderRaw)?.uuidString
        else { return nil }
        let date = Self.iso.date(from: createdAt)
            ?? Self.isoFractional.date(from: createdAt)
            ?? Date()
        let imageURL = record["image_url"]?.stringValue
        return DMMessage(
            id: id, threadID: threadID, senderID: senderID,
            content: content, imageURL: imageURL, createdAt: date
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
    static let dmMessageInserted = Notification.Name("dmMessageInserted")
    static let dmMessageDeleted  = Notification.Name("dmMessageDeleted")
}

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
