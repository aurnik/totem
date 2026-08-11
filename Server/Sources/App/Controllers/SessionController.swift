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

    /// Resolves the conversation for the caller plus the given participants,
    /// all of whom must be accepted buddies of the caller. The combination
    /// *is* the identity, so this is idempotent: the same people always get
    /// the same conversation back. Creating a group also opens its sitting —
    /// that's the deliberate act a group needs to be live, where a 1:1 sitting
    /// opens on first traffic instead.
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

        let conversation = try await gateway.conversation(for: [userID] + others)
        let conversationID = try conversation.requireID()
        if conversation.isGroup {
            let sitting = try await gateway.sittings.open(
                conversationID, participants: conversation.participants, at: Date())
            let info = try await gateway.sessionInfo(
                id: conversationID, participants: conversation.participants,
                startedAt: sitting.startedAt, on: req.db)
            for participant in conversation.participants {
                await gateway.connections.send(.sessionStarted(info), to: participant)
            }
            return info
        }
        let startedAt = (try? await gateway.sittings.get(conversationID))?.startedAt ?? Date()
        return try await gateway.sessionInfo(
            id: conversationID, participants: conversation.participants,
            startedAt: startedAt, on: req.db)
    }
}

extension SessionInfo: Content {}
