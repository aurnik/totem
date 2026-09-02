import APNSCore
import Fluent
import Redis
import TotemKit
import Vapor
import VaporAPNS

/// Device-token registration and the sign-on-push user setting.
struct PushController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let push = routes.grouped("push")
        push.post("token", use: registerToken)
        push.get("settings", use: getSettings)
        push.post("settings", use: setSettings)
    }

    struct TokenBody: Content {
        let token: String
    }

    private func registerToken(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(UserModel.self)
        let body = try req.content.decode(TokenBody.self)
        guard body.token.count <= 200, body.token.allSatisfy(\.isHexDigit) else {
            throw Abort(.badRequest, reason: "Not an APNs token.")
        }
        // Tokens can move between users on a shared device — reassign.
        if let existing = try await PushTokenModel.query(on: req.db)
            .filter(\.$token == body.token).first() {
            existing.$user.id = try user.requireID()
            try await existing.save(on: req.db)
        } else {
            try await PushTokenModel(userID: try user.requireID(), token: body.token)
                .save(on: req.db)
        }
        return .ok
    }

    private func getSettings(_ req: Request) async throws -> PushSettings {
        let user = try req.auth.require(UserModel.self)
        return PushSettings(signOnPushes: user.signOnPushes)
    }

    private func setSettings(_ req: Request) async throws -> PushSettings {
        let user = try req.auth.require(UserModel.self)
        let settings = try req.content.decode(PushSettings.self)
        user.signOnPushes = settings.signOnPushes
        try await user.save(on: req.db)
        return settings
    }
}

/// APNs for what happens while the app isn't looking: the icon badge counting
/// buddies online, and alerts for buddy requests and, if asked, sign-ons.
actor Pusher {
    static let bundleID = "com.deadsimple.totem"

    private let app: Application

    init(app: Application) {
        self.app = app
    }

    var isConfigured: Bool {
        Environment.get("APNS_KEY_PEM") != nil
    }

    /// Push to every accepted buddy of `userID` who wants sign-on pushes and
    /// isn't currently connected (connected clients get the presence frame
    /// and raise a local notification themselves, unthrottled — the window
    /// below covers only the pushes).
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
                    // A sign-on notice is stale once the buddy signs off again.
                    await send("signed on", about: userID, handle: handle,
                               kind: "signon", expiresIn: 30 * 60, to: row)
                }
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    /// The icon badge is how many of the user's buddies are online. It is
    /// recomputed from presence at every offline↔online transition rather
    /// than counted up, so it can't drift and zero clears it — and it goes to
    /// every token, connected or not: a value rather than an event, so a
    /// redundant delivery costs nothing and needs no reconciling.
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
                    // Absolute values supersede each other, so one collapse ID
                    // per recipient replaces an undelivered older badge rather
                    // than playing it back first. Past an hour a stored value
                    // is likelier wrong than right; the app corrects it on open.
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

    /// The window's one sign-on push about `subject`, claimed for `recipient`.
    /// It lives in Redis rather than in memory so a deploy mid-window doesn't
    /// hand everyone a second push, and `SET NX` means a repeat sign-on can't
    /// extend the window it's being refused by.
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
            // With no window to claim there's no way to promise a rate, and an
            // unthrottled push is the failure worth avoiding.
            app.logger.warning("sign-on push throttle unavailable: \(error)")
            return false
        }
    }

    /// A buddy request leaves no trace the recipient will see until they next
    /// open the app, so it isn't gated on a setting or a throttle — the server
    /// refuses duplicate requests, making this at most one alert per requester.
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

    /// The requester's side of `buddyRequested`: nothing told them their
    /// request went through, and a buddyship forms once per pair, so this is
    /// ungated too.
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

    /// Every alert Totem sends is one person doing one thing, so the handle is
    /// the title and the body is only the verb — the same shape the client's
    /// local sign-on notification uses, since a buddy signing on has to read
    /// identically whether it arrived over the socket or over APNs. Threading
    /// by the subject's user ID groups everything about one person, and
    /// collapsing by kind lets a newer alert replace an undelivered older one
    /// the way the local notification replaces itself by identifier.
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

    /// A token APNs calls dead is dropped so the device's next registration
    /// starts clean; any other failure is logged and forgotten.
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

/// `{"aps":{"badge":n}}` and nothing else: an alert-type push with no alert
/// and no sound sets the icon badge without showing or sounding anything.
private struct BadgeMessage: APNSMessage {
    struct APS: Encodable {
        let badge: Int
    }

    let aps: APS

    init(count: Int) {
        aps = APS(badge: count)
    }
}

extension TotemKit.PushSettings: Content {}
