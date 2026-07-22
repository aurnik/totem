import Fluent
import TotemKit
import Vapor

struct BuddyController: RouteCollection {
    let gateway: GatewayController

    func boot(routes: RoutesBuilder) throws {
        let buddies = routes.grouped("buddies")
        buddies.get(use: list)
        buddies.post("requests", use: request)
        buddies.post("requests", ":id", "accept", use: accept)
        buddies.delete(":id", use: remove)
    }

    /// Own rows plus incoming pending requests, as TotemKit.Buddy DTOs.
    func list(req: Request) async throws -> [Buddy] {
        let userID = try req.auth.require(UserModel.self).requireID()
        let own = try await BuddyModel.query(on: req.db)
            .filter(\.$user.$id == userID)
            .with(\.$buddy)
            .all()
        let incoming = try await BuddyModel.query(on: req.db)
            .filter(\.$buddy.$id == userID)
            .filter(\.$status == .pending)
            .with(\.$user)
            .all()
        var result = try own.map {
            Buddy(id: try $0.requireID(), user: $0.buddy.dto, status: $0.status, incoming: false)
        }
        for row in incoming {
            let openRequests = try await BuddyModel.query(on: req.db)
                .filter(\.$user.$id == row.$user.id)
                .filter(\.$status == .pending)
                .count()
            result.append(Buddy(
                id: try row.requireID(), user: row.user.dto, status: row.status,
                incoming: true, openRequestCount: openRequests))
        }
        return result
    }

    struct BuddyRequest: Content {
        let handle: String
    }

    /// Discovery is by handle only (spec §8). Creates one pending row, me → them.
    func request(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(UserModel.self)
        let userID = try user.requireID()
        let body = try req.content.decode(BuddyRequest.self)

        guard let target = try await UserModel.query(on: req.db)
            .filter(\.$handle == body.handle.lowercased())
            .first()
        else { throw Abort(.notFound, reason: "No user with that handle.") }
        let targetID = try target.requireID()
        guard targetID != userID else { throw Abort(.badRequest, reason: "That's you.") }

        let count = try await BuddyModel.query(on: req.db).filter(\.$user.$id == userID).count()
        guard count < Limits.maxBuddies else {
            throw Abort(.conflict, reason: "Buddy list is capped at \(Limits.maxBuddies).")
        }

        let existing = try await BuddyModel.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$buddy.$id == targetID)
            .first()
        guard existing == nil else { throw Abort(.conflict, reason: "Request already exists.") }

        try await BuddyModel(userID: userID, buddyID: targetID, status: .pending).save(on: req.db)
        await gateway.buddyRequestReceived(by: targetID, from: user.dto)
        return .created
    }

    /// Accepting marks the original row accepted and creates the reciprocal
    /// accepted row. Only then does either side see the other's presence.
    func accept(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserModel.self).requireID()
        guard let id = req.parameters.get("id", as: UUID.self),
              let row = try await BuddyModel.find(id, on: req.db),
              row.$buddy.id == userID,
              row.status == .pending
        else { throw Abort(.notFound) }

        row.status = .accepted
        try await row.save(on: req.db)
        try await BuddyModel(userID: userID, buddyID: row.$user.id, status: .accepted).save(on: req.db)
        await gateway.buddyshipFormed(userID, row.$user.id)
        return .ok
    }

    /// Removes both directions.
    func remove(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(UserModel.self).requireID()
        guard let id = req.parameters.get("id", as: UUID.self),
              let row = try await BuddyModel.find(id, on: req.db),
              row.$user.id == userID || row.$buddy.id == userID
        else { throw Abort(.notFound) }

        let (a, b) = (row.$user.id, row.$buddy.id)
        try await BuddyModel.query(on: req.db)
            .group(.or) { or in
                or.group(.and) { $0.filter(\.$user.$id == a).filter(\.$buddy.$id == b) }
                or.group(.and) { $0.filter(\.$user.$id == b).filter(\.$buddy.$id == a) }
            }
            .delete()
        return .ok
    }
}

extension TotemKit.Buddy: Content {}
extension TotemKit.User: Content {}
