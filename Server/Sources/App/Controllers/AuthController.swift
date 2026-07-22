import Fluent
import TotemKit
import Vapor

extension UserModel: Authenticatable {}

struct TokenAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard let token = try await TokenModel.query(on: request.db)
            .filter(\.$value == bearer.token)
            .with(\.$user)
            .first()
        else { return }
        request.auth.login(token.user)
    }
}

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        // TODO: replace with Sign in with Apple verification (spec §8).
        // Dev-only: trusts the handle it is given.
        auth.post("dev", use: devLogin)
    }

    struct DevLoginRequest: Content {
        let handle: String
        let displayName: String?
    }

    struct LoginResponse: Content {
        let token: String
        let user: TotemKit.User
    }

    func devLogin(req: Request) async throws -> LoginResponse {
        let body = try req.content.decode(DevLoginRequest.self)
        let handle = body.handle.lowercased()
        guard Limits.handleLength.contains(handle.count),
              handle.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else {
            throw Abort(.badRequest, reason: "Handle must be 3–16 letters, numbers, or underscores.")
        }

        let user: UserModel
        if let existing = try await UserModel.query(on: req.db).filter(\.$handle == handle).first() {
            user = existing
        } else {
            user = UserModel(handle: handle, displayName: body.displayName ?? handle)
            try await user.save(on: req.db)
        }

        let token = TokenModel(value: [UInt8].random(count: 32).hex, userID: try user.requireID())
        try await token.save(on: req.db)
        return LoginResponse(token: token.value, user: user.dto)
    }
}
