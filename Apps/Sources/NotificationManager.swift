import Foundation
import TotemKit
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Local sign-on notifications. Throttled to one per buddy per 30 minutes
/// (spec §7) — unthrottled sign-on alerts are uninstall-inducing. Permission
/// is requested contextually once buddies exist, never at launch.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let throttle = Limits.signOnPushThrottle
    private var lastNotified: [UUID: Date] = [:]

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
        let now = Date()
        if let last = lastNotified[userID], now.timeIntervalSince(last) < Self.throttle {
            return
        }
        lastNotified[userID] = now

        let content = UNMutableNotificationContent()
        content.title = handle
        content.body = "signed on"
        content.sound = .default
        content.threadIdentifier = userID.uuidString
        let request = UNNotificationRequest(
            identifier: "signon-\(userID.uuidString)", content: content, trigger: nil)
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
