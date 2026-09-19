import Fluent
import TotemKit
import Vapor

/// Profile writes. Reads go out with the `welcome` frame, not through a route here.
struct ProfileController: RouteCollection {
    let gateway: GatewayController

    func boot(routes: RoutesBuilder) throws {
        routes.grouped("me").post("avatar", use: setAvatar)
    }

    func setAvatar(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(UserModel.self)
        let avatar = try req.content.decode(Avatar.self)
        guard (0...1).contains(avatar.skinTone), (0...1).contains(avatar.hair),
              avatar.doodle?.isValid ?? true else {
            throw Abort(.badRequest, reason: "Avatar values out of range.")
        }
        user.avatarJSON = String(decoding: try JSONEncoder().encode(avatar), as: UTF8.self)
        try await user.save(on: req.db)
        // Everyone rendering this user patches their cached copy in place.
        await gateway.fanOutAvatar(avatar, of: try user.requireID())
        return .ok
    }
}

extension TotemKit.Avatar: Content {}
