import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Local sign-on notifications, raised on every sign-on. Permission is
/// requested contextually once buddies exist, never at launch.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermissionIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "askedNotificationPermission") else {
            registerForRemotePushes()
            return
        }
        defaults.set(true, forKey: "askedNotificationPermission")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                Task { @MainActor in self.registerForRemotePushes() }
            }
        }
    }

    /// APNs registration for server-side sign-on pushes. Harmless on builds
    /// without the push entitlement (dev builds) — registration just fails
    /// via the delegate and no token is ever sent.
    private func registerForRemotePushes() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func buddySignedOn(_ userID: UUID, handle: String) {
        let content = UNMutableNotificationContent()
        content.title = handle
        content.body = "signed on"
        content.sound = .default
        content.threadIdentifier = userID.uuidString
        // A fresh identifier per alert: reusing one replaces the buddy's
        // previous notice instead of stacking a new one beside it.
        let request = UNNotificationRequest(
            identifier: "signon-\(userID.uuidString)-\(UUID().uuidString)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Show banners even while the app is frontmost — presence updates only
    /// arrive while the socket is alive, which on iOS means foregrounded.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
