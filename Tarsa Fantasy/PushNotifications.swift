import UIKit
import UserNotifications

// APNs plumbing. The app is otherwise pure SwiftUI; this AppDelegate (installed
// via UIApplicationDelegateAdaptor) exists only to receive the device-token and
// notification callbacks that UNUserNotificationCenter can't deliver straight to
// a SwiftUI `App`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await NotificationManager.shared.handleDeviceToken(token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("APNs registration failed: \(error.localizedDescription)")
        #endif
    }

    // Show banners while the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    // On tap, route a deep link if the payload carries one. Mirrors the
    // in-process NotificationCenter pattern the app already uses for live data.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let link = info["deep_link"] as? String, let url = URL(string: link) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .pushDeepLink, object: url)
        }
    }
}

extension Notification.Name {
    static let pushDeepLink = Notification.Name("pushDeepLink")
}

// Owns the device-token lifecycle and the permission prompt. The token is cached
// locally because it can arrive before the user is signed in; it's (re-)uploaded
// to the backend whenever a session is available.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private let tokenKey = "push.deviceToken"
    private(set) var deviceToken: String?

    private init() {
        deviceToken = UserDefaults.standard.string(forKey: tokenKey)
    }

    // Debug builds register against the APNs sandbox; release/TestFlight builds
    // against production. The backend uses this to pick the right APNs host.
    private var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    // Ask for permission (the system only shows the dialog the first time) and,
    // when granted, kick off APNs registration. Safe to call repeatedly.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }

    func handleDeviceToken(_ token: String) async {
        deviceToken = token
        UserDefaults.standard.set(token, forKey: tokenKey)
        await uploadTokenIfPossible()
    }

    // Push the cached token to the backend. No-ops when there's no token yet or
    // the user isn't signed in (the RPC rejects it) — the next sign-in retries.
    func uploadTokenIfPossible() async {
        guard let token = deviceToken else { return }
        try? await RemoteService.shared.registerDeviceToken(token, environment: environment)
    }

    func clearOnSignOut() async {
        guard let token = deviceToken else { return }
        await RemoteService.shared.unregisterDeviceToken(token)
    }
}
