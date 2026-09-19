import Fluent
import TotemKit
import Vapor

/// Device-token registration and the sign-on-push setting.
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
        // A token can move between users on a shared device.
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

extension TotemKit.PushSettings: Content {}
