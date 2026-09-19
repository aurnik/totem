import APNSCore
import Fluent
import Redis
import TotemKit
import Vapor
import VaporAPNS

/// APNs for what happens while the app is closed: the icon badge counting
/// buddies online, buddy-request alerts, and opt-in sign-on alerts.
actor Pusher {
    static let bundleID = "com.deadsimple.totem"

    private let app: Application

    init(app: Application) {
        self.app = app
    }

    var isConfigured: Bool {
        Environment.get("APNS_KEY_PEM") != nil
    }

    /// Pushes to every accepted buddy who opted in and is not connected.
    /// Connected clients get the presence frame and raise a local alert.
    func buddySignedOn(_ userID: UUID, buddyIDs: [UUID], connections: ConnectionManager) async {
        guard isConfigured else { return }
        do {
            guard let handle = try await UserModel.find(userID, on: app.db)?.handle else { return }
            for buddyID in buddyIDs {
                guard await !connections.isConnected(buddyID),
                      let buddy = try await UserModel.find(buddyID, on: app.db),
                      buddy.signOnPushes
                else { continue }
                let tokens = try await PushTokenModel.query(on: app.db)
                    .filter(\.$user.$id == buddyID).all()
                guard !tokens.isEmpty,
                      await claimPushWindow(recipient: buddyID, subject: userID)
                else { continue }
                for row in tokens {
                    await send("signed on", about: userID, handle: handle,
                               kind: "signon", expiresIn: 30 * 60, to: row)
                }
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    /// The badge is recomputed from presence on every offline/online
    /// transition and sent to every token, so it never drifts and zero clears it.
    func refreshBadges(of recipients: [UUID]) async {
        guard isConfigured else { return }
        for recipient in recipients {
            do {
                let tokens = try await PushTokenModel.query(on: app.db)
                    .filter(\.$user.$id == recipient).all()
                guard !tokens.isEmpty else { continue }
                let online = try await PresenceStore(redis: app.redis).presentCount(
                    among: BuddyModel.acceptedBuddyIDs(of: recipient, on: app.db))
                for row in tokens {
                    // One collapse ID per recipient so a newer value replaces
                    // an undelivered older one.
                    let request = APNSRequest(
                        message: BadgeMessage(count: online), deviceToken: row.token,
                        pushType: .alert,
                        expiration: .timeIntervalSince1970InSeconds(
                            Int(Date().timeIntervalSince1970 + 60 * 60)),
                        priority: .immediately, apnsID: nil, topic: Self.bundleID,
                        collapseID: "badge")
                    await deliver(to: row) { _ = try await app.apns.client.send(request) }
                }
            } catch {
                app.logger.report(error: error)
            }
        }
    }

    /// One sign-on push per buddy per `Limits.signOnPushThrottle`, claimed in
    /// Redis with `SET NX` so a repeat sign-on cannot extend the window.
    private func claimPushWindow(recipient: UUID, subject: UUID) async -> Bool {
        let key: RedisKey = "signon-push:\(recipient.uuidString):\(subject.uuidString)"
        do {
            let result = try await app.redis.set(
                key, to: "1", onCondition: .keyDoesNotExist,
                expiration: .seconds(Int(Limits.signOnPushThrottle))
            ).get()
            if case .ok = result { return true }
            return false
        } catch {
            app.logger.warning("sign-on push throttle unavailable: \(error)")
            return false
        }
    }

    func buddyRequested(from user: User, to targetID: UUID) async {
        guard isConfigured else { return }
        do {
            for row in try await PushTokenModel.query(on: app.db)
                .filter(\.$user.$id == targetID).all() {
                await send("sent you a friend request", about: user.id, handle: user.handle,
                           kind: "request", expiresIn: 24 * 60 * 60, to: row)
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    func buddyRequestAccepted(by accepterID: UUID, handle: String, to requesterID: UUID) async {
        guard isConfigured else { return }
        do {
            for row in try await PushTokenModel.query(on: app.db)
                .filter(\.$user.$id == requesterID).all() {
                await send("accepted your friend request", about: accepterID, handle: handle,
                           kind: "accept", expiresIn: 24 * 60 * 60, to: row)
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    /// Handle as title, verb as body, matching the client's local notification.
    /// Threaded by subject and collapsed by kind.
    private func send(_ body: String, about userID: UUID, handle: String, kind: String,
                      expiresIn: TimeInterval, to row: PushTokenModel) async {
        var notification = APNSAlertNotification(
            alert: .init(title: .raw(handle), body: .raw(body)),
            expiration: .timeIntervalSince1970InSeconds(
                Int(Date().timeIntervalSince1970 + expiresIn)),
            priority: .immediately,
            topic: Self.bundleID,
            payload: EmptyPayload(),
            sound: .default,
            threadID: userID.uuidString)
        notification.collapseID = "\(kind)-\(userID)"
        await deliver(to: row) {
            try await app.apns.client.sendAlertNotification(notification, deviceToken: row.token)
        }
    }

    /// Drops tokens APNs reports as dead; logs any other failure.
    private func deliver(to row: PushTokenModel, _ attempt: () async throws -> Void) async {
        do {
            try await attempt()
        } catch let error as APNSError where error.reason == .badDeviceToken
            || error.reason == .unregistered {
            try? await row.delete(on: app.db)
        } catch {
            app.logger.warning("push failed: \(error)")
        }
    }
}

/// `{"aps":{"badge":n}}`: sets the badge without an alert or sound.
private struct BadgeMessage: APNSMessage {
    struct APS: Encodable {
        let badge: Int
    }

    let aps: APS

    init(count: Int) {
        aps = APS(badge: count)
    }
}
