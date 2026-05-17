import Foundation
import Supabase

// Subscribes to a specific draft's row + its picks. Any insert/update is
// surfaced via NotificationCenter so AppState (and the DraftRoomView) can
// reload state. One listener at a time; calling start(draftID:) again
// replaces the previous subscription.

actor DraftListener {
    static let shared = DraftListener()

    private var channel: RealtimeChannelV2?
    private var currentDraftID: String?

    func start(draftID: String) async {
        if currentDraftID == draftID, channel != nil { return }
        await stop()
        currentDraftID = draftID

        let client = SupabaseConfig.sharedClient
        let ch = client.channel("draft-\(draftID)")

        guard let draftUUID = UUID(uuidString: draftID) else { return }
        let draftChanges = ch.postgresChange(
            AnyAction.self,
            schema: "public", table: "drafts",
            filter: .eq("id", value: draftUUID)
        )
        let pickChanges = ch.postgresChange(
            AnyAction.self,
            schema: "public", table: "draft_picks",
            filter: .eq("draft_id", value: draftUUID)
        )

        do {
            try await ch.subscribeWithError()
        } catch {
            print("DraftListener subscribe failed: \(error)")
            return
        }
        channel = ch

        Task.detached {
            for await _ in draftChanges {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .draftUpdated, object: nil, userInfo: ["draftID": draftID]
                    )
                }
            }
        }
        Task.detached {
            for await _ in pickChanges {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .draftPicksUpdated, object: nil, userInfo: ["draftID": draftID]
                    )
                }
            }
        }
    }

    func stop() async {
        if let ch = channel { await ch.unsubscribe() }
        channel = nil
        currentDraftID = nil
    }
}

extension Notification.Name {
    static let draftUpdated      = Notification.Name("draftUpdated")
    static let draftPicksUpdated = Notification.Name("draftPicksUpdated")
}
