import Fluent
import TotemKit
import Vapor

/// Profile data beyond auth — currently just the avatar settings.
struct ProfileController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let me = routes.grouped("me")
        me.get(use: current)
        me.post("avatar", use: setAvatar)
    }

    func current(req: Request) async throws -> TotemKit.User {
        try req.auth.require(UserModel.self).dto
    }

    func setAvatar(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(UserModel.self)
        let avatar = try req.content.decode(Avatar.self)
        guard (0...1).contains(avatar.skinTone), (0...1).contains(avatar.hair) else {
            throw Abort(.badRequest, reason: "Avatar values out of range.")
        }
        user.avatarJSON = String(decoding: try JSONEncoder().encode(avatar), as: UTF8.self)
        try await user.save(on: req.db)
        return .ok
    }
}

extension TotemKit.Avatar: Content {}
