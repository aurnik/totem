import Fluent
import TotemKit
import Vapor

/// Profile data beyond auth — currently just the avatar settings. Reads go
/// out with the `welcome` frame rather than through a route here.
struct ProfileController: RouteCollection {
    let gateway: GatewayController

    func boot(routes: RoutesBuilder) throws {
        routes.grouped("me").post("avatar", use: setAvatar)
    }

    func setAvatar(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(UserModel.self)
        let avatar = try req.content.decode(Avatar.self)
        guard (0...1).contains(avatar.skinTone), (0...1).contains(avatar.hair) else {
            throw Abort(.badRequest, reason: "Avatar values out of range.")
        }
        user.avatarJSON = String(decoding: try JSONEncoder().encode(avatar), as: UTF8.self)
        try await user.save(on: req.db)
        // Everyone already looking at this user updates in place; nobody has
        // to refetch a buddy list to stop seeing the old face.
        await gateway.fanOutAvatar(avatar, of: try user.requireID())
        return .ok
    }
}

extension TotemKit.Avatar: Content {}
