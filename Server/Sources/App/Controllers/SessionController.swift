import Fluent
import TotemKit
import Vapor

struct SessionController: RouteCollection {
    let gateway: GatewayController

    func boot(routes: RoutesBuilder) throws {
        let sessions = routes.grouped("sessions")
        sessions.post(use: create)
    }

    struct CreateRequest: Content {
        let participantIDs: [UUID]
    }

    /// Creates a session with the caller plus the given participants, all of
    /// whom must be accepted buddies of the caller. Two participants reuses
    /// any open 1:1 session; three or more is a group chat.
    func create(req: Request) async throws -> SessionInfo {
        let user = try req.auth.require(UserModel.self)
        let userID = try user.requireID()
        let body = try req.content.decode(CreateRequest.self)
        let others = Array(Set(body.participantIDs)).filter { $0 != userID }
        guard !others.isEmpty else {
            throw Abort(.badRequest, reason: "A chat needs at least one other participant.")
        }

        for id in others {
            guard try await gateway.areAcceptedBuddies(userID, id) else {
                throw Abort(.forbidden, reason: "All participants must be your buddies.")
            }
        }

        let session: SessionModel
        if others.count == 1 {
            session = try await gateway.openSession(between: userID, and: others[0])
        } else {
            session = SessionModel(participants: [userID] + others.sorted { $0.uuidString < $1.uuidString })
            try await session.save(on: req.db)
        }

        let info = try await gateway.sessionInfo(session, on: req.db)
        if session.isGroup {
            for participant in session.participants {
                await gateway.connections.send(.sessionStarted(info), to: participant)
            }
        }
        return info
    }
}

extension SessionInfo: Content {}
