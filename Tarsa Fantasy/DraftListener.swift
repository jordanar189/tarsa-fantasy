import Foundation
import Supabase
import UIKit

// Subscribes to a specific draft's row + its picks. Any insert/update is
// surfaced via NotificationCenter so AppState (and the DraftRoomView) can
// reload state. One listener at a time; calling start(draftID:) again
// replaces the previous subscription. Subscribes with retry, and on every
// app-foreground re-establishes a dead channel and posts the update
// notifications so the room re-fetches the full pick snapshot — a silently
// missed pick mid-draft is the worst realtime failure mode in the app.

actor DraftListener {
    static let shared = DraftListener()

    private var channel: RealtimeChannelV2?
    private var currentDraftID: String?
    private var foregroundObserver: (any NSObjectProtocol)?

    func start(draftID: String) async {
        if currentDraftID == draftID, channel != nil { return }
        await stop()
        currentDraftID = draftID
        installForegroundHook()

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

        guard await RealtimeResilience.subscribe(ch, label: "DraftListener") else {
            // Foreground hook retries; currentDraftID stays set for it.
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
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
    }

    // Re-establish after backgrounding and tell the room to re-pull the full
    // draft + picks snapshot (deltas delivered while backgrounded are lost).
    private func installForegroundHook() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            Task { await DraftListener.shared.foregroundResync() }
        }
    }

    private func foregroundResync() async {
        guard let draftID = currentDraftID else { return }
        if channel == nil {
            currentDraftID = nil   // force start() past its idempotence guard
            await start(draftID: draftID)
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .draftUpdated, object: nil, userInfo: ["draftID": draftID])
            NotificationCenter.default.post(
                name: .draftPicksUpdated, object: nil, userInfo: ["draftID": draftID])
        }
    }
}

extension Notification.Name {
    static let draftUpdated      = Notification.Name("draftUpdated")
    static let draftPicksUpdated = Notification.Name("draftPicksUpdated")
}
