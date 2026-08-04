import APNSCore
import Fluent
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

    struct Settings: Content {
        let signOnPushes: Bool
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

    private func getSettings(_ req: Request) async throws -> Settings {
        let user = try req.auth.require(UserModel.self)
        return Settings(signOnPushes: user.signOnPushes)
    }

    private func setSettings(_ req: Request) async throws -> Settings {
        let user = try req.auth.require(UserModel.self)
        let settings = try req.content.decode(Settings.self)
        user.signOnPushes = settings.signOnPushes
        try await user.save(on: req.db)
        return settings
    }
}

/// APNs alerts for the two things that happen while the app isn't looking:
/// buddies signing on, and buddy requests arriving.
actor Pusher {
    static let bundleID = "com.deadsimple.totem"

    private let app: Application
    private var lastSent: [String: Date] = [:]

    init(app: Application) {
        self.app = app
    }

    var isConfigured: Bool {
        Environment.get("APNS_KEY_PEM") != nil
    }

    /// Push to every accepted buddy of `userID` who wants sign-on pushes and
    /// isn't currently connected (connected clients get the presence frame
    /// and raise a local notification themselves). Throttled to one per
    /// watched buddy per 30 minutes, mirroring the client-side throttle.
    func buddySignedOn(_ userID: UUID, buddyIDs: [UUID], connections: ConnectionManager) async {
        guard isConfigured else { return }
        do {
            guard let handle = try await UserModel.find(userID, on: app.db)?.handle else { return }
            for buddyID in buddyIDs {
                guard await !connections.isConnected(buddyID),
                      let buddy = try await UserModel.find(buddyID, on: app.db),
                      buddy.signOnPushes
                else { continue }
                let throttleKey = "\(buddyID)-\(userID)"
                if let last = lastSent[throttleKey], Date().timeIntervalSince(last) < 30 * 60 {
                    continue
                }
                let tokens = try await PushTokenModel.query(on: app.db)
                    .filter(\.$user.$id == buddyID).all()
                guard !tokens.isEmpty else { continue }
                lastSent[throttleKey] = Date()
                for row in tokens {
                    // A sign-on notice is stale once the buddy signs off again.
                    await send("\(handle) signed on", expiresIn: 30 * 60, to: row)
                }
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    /// A buddy request leaves no trace the recipient will see until they next
    /// open the app, so it isn't gated on a setting or a throttle — the server
    /// refuses duplicate requests, making this at most one alert per requester.
    func buddyRequested(from handle: String, to targetID: UUID) async {
        guard isConfigured else { return }
        do {
            for row in try await PushTokenModel.query(on: app.db)
                .filter(\.$user.$id == targetID).all() {
                await send("\(handle) sent you a friend request", expiresIn: 24 * 60 * 60, to: row)
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    private func send(_ title: String, expiresIn: TimeInterval, to row: PushTokenModel) async {
        do {
            try await app.apns.client.sendAlertNotification(
                APNSAlertNotification(
                    alert: .init(title: .raw(title)),
                    expiration: .timeIntervalSince1970InSeconds(
                        Int(Date().timeIntervalSince1970 + expiresIn)),
                    priority: .immediately,
                    topic: Self.bundleID,
                    payload: EmptyPayload()),
                deviceToken: row.token)
        } catch let error as APNSError where error.reason == .badDeviceToken
            || error.reason == .unregistered {
            try? await row.delete(on: app.db)
        } catch {
            app.logger.warning("push failed: \(error)")
        }
    }
}
