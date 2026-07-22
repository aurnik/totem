import Fluent
import Foundation
import TotemKit
import Vapor

/// The stateful WebSocket gateway: presence transitions, heartbeats, message
/// relay, and session auto-archive (spec §3, §4).
struct GatewayController {
    let app: Application
    let connections: ConnectionManager

    var presence: PresenceStore { PresenceStore(redis: app.redis) }
    var db: Database { app.db }

    func handleUpgrade(req: Request, ws: WebSocket) async {
        guard let user = req.auth.get(UserModel.self), let userID = user.id else {
            try? await ws.close(code: .policyViolation)
            return
        }
        let generation = await connections.register(ws, for: userID)

        ws.onBinary { _, buffer in
            await handleFrame(buffer: Data(buffer.readableBytesView), from: userID)
        }
        ws.onText { _, text in
            await handleFrame(buffer: Data(text.utf8), from: userID)
        }
        ws.onClose.whenComplete { _ in
            Task { await handleClose(userID: userID, ws: ws, generation: generation) }
        }

        await signOn(userID: userID)
    }

    // MARK: - Lifecycle

    private func signOn(userID: UUID) async {
        do {
            // Preserve an existing away state on reconnect; otherwise online.
            let existing = try await presence.get(for: userID)
            let current = existing.state == .offline ? Presence(state: .online) : existing
            try await presence.set(current, for: userID)

            let buddyIDs = try await acceptedBuddyIDs(of: userID)
            var snapshot: [String: Presence] = [:]
            for id in buddyIDs {
                snapshot[id.uuidString] = try await presence.get(for: id)
            }
            await connections.send(.welcome(self_: current, buddies: snapshot), to: userID)
            await fanOut(.presence(userID: userID, presence: current), toBuddiesOf: userID)
            try await deliverPending(to: userID)
        } catch {
            app.logger.report(error: error)
        }
    }

    /// Non-deliberate drop: hold the last presence for the TTL window so a user
    /// in a tunnel doesn't flap to offline (spec §10). If they haven't
    /// reconnected when the grace elapses, they go offline.
    private func handleClose(userID: UUID, ws: WebSocket, generation: Int) async {
        await connections.unregister(userID, ifStill: ws)
        try? await Task.sleep(for: .seconds(90))
        guard await connections.generation(of: userID) == generation,
              await !connections.isConnected(userID)
        else { return }
        await goOffline(userID: userID)
    }

    private func goOffline(userID: UUID) async {
        do {
            try await presence.markOffline(for: userID)
            await fanOut(.presence(userID: userID, presence: .offline), toBuddiesOf: userID)
            try await closeOpenSessions(of: userID)
        } catch {
            app.logger.report(error: error)
        }
    }

    // MARK: - Frames

    private func handleFrame(buffer: Data, from userID: UUID) async {
        guard let frame = try? WireCoder.decoder().decode(ClientFrame.self, from: buffer) else {
            await connections.send(.error("Unrecognized frame."), to: userID)
            return
        }
        do {
            switch frame {
            case .heartbeat:
                try await presence.refresh(for: userID)

            case .setPresence(let state, let awayMessage):
                guard state != .offline else {
                    await goOffline(userID: userID)
                    return
                }
                let message = awayMessage.map { String($0.prefix(Limits.awayMessageMaxLength)) }
                let updated = Presence(state: state, awayMessage: message)
                try await presence.set(updated, for: userID)
                await fanOut(.presence(userID: userID, presence: updated), toBuddiesOf: userID)

            case .signOff:
                await goOffline(userID: userID)

            case .sendMessage(let recipientID, let body, let clientMessageID):
                try await relayMessage(
                    from: userID, to: recipientID, body: body, clientMessageID: clientMessageID)

            case .typing(let recipientID):
                if try await areAcceptedBuddies(userID, recipientID) {
                    await connections.send(.typing(userID: userID), to: recipientID)
                }
            }
        } catch {
            app.logger.report(error: error)
            await connections.send(.error("Internal error."), to: userID)
        }
    }

    private func relayMessage(
        from senderID: UUID, to recipientID: UUID, body: String, clientMessageID: UUID
    ) async throws {
        guard try await areAcceptedBuddies(senderID, recipientID) else {
            await connections.send(.error("Not buddies."), to: senderID)
            return
        }
        let session = try await openSession(between: senderID, and: recipientID)
        let message = MessageModel(sessionID: try session.requireID(), senderID: senderID, body: body)

        // Offline recipient: stored and delivered on their next sign-on (spec §6).
        if await connections.isConnected(recipientID) {
            message.deliveredAt = Date()
            try await message.save(on: db)
            await connections.send(.message(message.dto), to: recipientID)
        } else {
            try await message.save(on: db)
        }
        await connections.send(
            .messageSent(clientMessageID: clientMessageID, message: message.dto), to: senderID)
    }

    private func deliverPending(to userID: UUID) async throws {
        let pending = try await MessageModel.query(on: db)
            .join(SessionModel.self, on: \MessageModel.$session.$id == \SessionModel.$id)
            .filter(\.$deliveredAt == nil)
            .filter(\.$senderID != userID)
            .group(.or) { or in
                or.filter(SessionModel.self, \.$participantA == userID)
                or.filter(SessionModel.self, \.$participantB == userID)
            }
            .sort(\.$sentAt)
            .all()
        for message in pending {
            message.deliveredAt = Date()
            try await message.save(on: db)
            await connections.send(.message(message.dto), to: userID)
        }
    }

    // MARK: - Sessions

    private func openSession(between a: UUID, and b: UUID) async throws -> SessionModel {
        let query = SessionModel.query(on: db)
            .filter(\.$endedAt == nil)
            .group(.or) { or in
                or.group(.and) { $0.filter(\.$participantA == a).filter(\.$participantB == b) }
                or.group(.and) { $0.filter(\.$participantA == b).filter(\.$participantB == a) }
            }
        if let existing = try await query.first() {
            return existing
        }
        let session = SessionModel(participantA: a, participantB: b)
        try await session.save(on: db)
        return session
    }

    /// Either party going offline ends the session for both (spec §2, §6).
    private func closeOpenSessions(of userID: UUID) async throws {
        let open = try await SessionModel.query(on: db)
            .filter(\.$endedAt == nil)
            .group(.or) { or in
                or.filter(\.$participantA == userID)
                or.filter(\.$participantB == userID)
            }
            .all()
        for session in open {
            session.endedAt = Date()
            try await session.save(on: db)
            await connections.send(.sessionClosed(sessionID: try session.requireID()),
                                   to: session.peer(of: userID))
        }
    }

    // MARK: - Buddies

    private func acceptedBuddyIDs(of userID: UUID) async throws -> [UUID] {
        try await BuddyModel.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$status == .accepted)
            .all()
            .map { $0.$buddy.id }
    }

    private func areAcceptedBuddies(_ a: UUID, _ b: UUID) async throws -> Bool {
        try await BuddyModel.query(on: db)
            .filter(\.$user.$id == a)
            .filter(\.$buddy.$id == b)
            .filter(\.$status == .accepted)
            .count() > 0
    }

    private func fanOut(_ frame: ServerFrame, toBuddiesOf userID: UUID) async {
        guard let buddyIDs = try? await acceptedBuddyIDs(of: userID) else { return }
        for id in buddyIDs {
            await connections.send(frame, to: id)
        }
    }
}
