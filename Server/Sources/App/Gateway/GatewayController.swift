import Fluent
import Foundation
import TotemKit
import Vapor

/// The stateful WebSocket gateway: presence transitions, heartbeats, message
/// relay, and session auto-archive (spec §3, §4).
struct GatewayController {
    let app: Application
    let connections: ConnectionManager
    let pusher: Pusher

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
        ws.onPong { _, _ in
            await connections.notePong(userID)
        }
        ws.onClose.whenComplete { _ in
            Task { await handleClose(userID: userID, ws: ws, generation: generation) }
        }

        await signOn(user: user, userID: userID)
    }

    /// A suspended iOS app never closes its socket — heartbeats just stop and
    /// the Redis key expires silently, which by itself notifies no one. This
    /// sweep turns TTL expiry into a real offline transition: fan-out to
    /// buddies, sessions archived, socket reaped (spec §3: server marks
    /// offline after 90s of silence).
    func startLivenessSweep() {
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                for userID in await self.connections.connectedUserIDs() {
                    let current = try? await self.presence.get(for: userID)
                    if current?.state ?? .offline == .offline {
                        await self.connections.expire(userID)
                        await self.goOffline(userID: userID)
                    }
                }
            }
        }
    }

    /// A new request pushes to the target's socket so no client ever needs a
    /// manual refresh to see it. A registered socket is no proof the app is
    /// awake to render that, though, so verify liveness and fall back to APNs
    /// — off the request path, since the ping costs 3s.
    func buddyRequestReceived(by targetID: UUID, from user: User) async {
        await connections.send(.buddyRequest(from: user), to: targetID)
        let (connections, pusher) = (self.connections, self.pusher)
        Task {
            guard await !connections.verifyAlive(targetID) else { return }
            await pusher.buddyRequested(from: user.handle, to: targetID)
        }
    }

    /// After a mutual accept, each party's welcome snapshot predates the
    /// buddyship — push each one's current presence to the other.
    func buddyshipFormed(_ a: UUID, _ b: UUID) async {
        do {
            await connections.send(.presence(userID: b, presence: try await presence.get(for: b)), to: a)
            await connections.send(.presence(userID: a, presence: try await presence.get(for: a)), to: b)
        } catch {
            app.logger.report(error: error)
        }
    }

    // MARK: - Lifecycle

    private func signOn(user: UserModel, userID: UUID) async {
        do {
            // Preserve an existing away state on reconnect; otherwise online.
            let existing = try await presence.get(for: userID)
            // Only a genuine offline→online transition is a sign-on; socket
            // reconnects within the presence TTL are not.
            let wasOffline = existing.state == .offline
            let current = wasOffline ? Presence(state: .online) : existing
            try await presence.set(current, for: userID)

            let buddyIDs = try await acceptedBuddyIDs(of: userID)
            var snapshot: [String: Presence] = [:]
            for id in buddyIDs {
                snapshot[id.uuidString] = try await presence.get(for: id)
            }
            let groupSessions = try await openGroupSessions(of: userID)
            var sessionInfos: [SessionInfo] = []
            for session in groupSessions {
                sessionInfos.append(try await sessionInfo(session, on: db))
            }
            let avatar = user.dto.avatar
            await connections.send(
                .welcome(self_: current, buddies: snapshot, sessions: sessionInfos,
                         freshSignOn: wasOffline, selfAvatar: avatar), to: userID)
            await fanOut(.presence(userID: userID, presence: current), toBuddiesOf: userID)
            // Buddies' cached lists were fetched at their own launch and can
            // predate this user ever publishing an avatar.
            if let avatar {
                await fanOutAvatar(avatar, of: userID)
            }
            if wasOffline {
                let pusher = self.pusher
                let connections = self.connections
                Task {
                    await pusher.buddySignedOn(userID, buddyIDs: buddyIDs, connections: connections)
                }
            }
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
        await connections.noteActivity(userID)
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

            case .sendMessage(let recipientID, let body, let clientMessageID, let dictated):
                try await relayMessage(
                    from: userID, to: recipientID, body: body,
                    clientMessageID: clientMessageID, dictated: dictated)

            case .sendSessionMessage(let sessionID, let body, let clientMessageID, let dictated):
                try await relaySessionMessage(
                    from: userID, sessionID: sessionID, body: body,
                    clientMessageID: clientMessageID, dictated: dictated)

            case .typing(let recipientID):
                if try await areAcceptedBuddies(userID, recipientID) {
                    await connections.send(.typing(userID: userID), to: recipientID)
                }

            // Live audio is best-effort relay: no ack, no error frames, no
            // ping-verify (chunks arrive ~10/s), nothing stored. A recipient
            // without the chat open just drops the chunks client-side.
            case .sendAudio(let recipientID, let chunk):
                guard chunk.count <= AudioWire.chunkMaxBytes,
                      try await areAcceptedBuddies(userID, recipientID)
                else { return }
                await connections.send(
                    .audio(conversationID: userID, senderID: userID, chunk: chunk),
                    to: recipientID)

            case .sendSessionAudio(let sessionID, let chunk):
                guard chunk.count <= AudioWire.chunkMaxBytes,
                      let session = try await SessionModel.find(sessionID, on: db),
                      session.includes(userID), session.endedAt == nil
                else { return }
                for participant in session.participants where participant != userID {
                    await connections.send(
                        .audio(conversationID: sessionID, senderID: userID, chunk: chunk),
                        to: participant)
                }

            case .setAudioMuted(let recipientID, let muted):
                guard try await areAcceptedBuddies(userID, recipientID) else { return }
                await connections.send(
                    .audioMuted(conversationID: userID, userID: userID, muted: muted),
                    to: recipientID)

            case .setSessionAudioMuted(let sessionID, let muted):
                guard let session = try await SessionModel.find(sessionID, on: db),
                      session.includes(userID), session.endedAt == nil
                else { return }
                for participant in session.participants where participant != userID {
                    await connections.send(
                        .audioMuted(conversationID: sessionID, userID: userID, muted: muted),
                        to: participant)
                }
            }
        } catch {
            app.logger.report(error: error)
            await connections.send(.error("Internal error."), to: userID)
        }
    }

    /// Messages are never stored server-side: pure relay, in one socket and
    /// out the others. An unreachable recipient means the message is refused,
    /// not spooled.
    private func relayMessage(
        from senderID: UUID, to recipientID: UUID, body: String, clientMessageID: UUID,
        dictated: Bool?
    ) async throws {
        guard try await areAcceptedBuddies(senderID, recipientID) else {
            await connections.send(.error("Not buddies."), to: senderID)
            return
        }
        // Sending is the moment liveness matters: ping-verify a nominally
        // connected recipient so a suspended app is discovered now rather
        // than when the sweep catches it.
        guard await connections.verifyAlive(recipientID) else {
            if await connections.isConnected(recipientID) {
                await connections.expire(recipientID)
                await goOffline(userID: recipientID)
            }
            await connections.send(.error("Message not delivered — they're offline."), to: senderID)
            return
        }
        let session = try await openSession(between: senderID, and: recipientID)
        let message = ChatMessage(
            id: UUID(), sessionID: try session.requireID(),
            senderID: senderID, body: body, sentAt: Date(), dictated: dictated)
        await connections.send(.message(message), to: recipientID)
        await connections.send(
            .messageSent(clientMessageID: clientMessageID, message: message), to: senderID)
    }

    /// Group message: relay to every connected member, store nothing.
    /// Offline members miss it — session-scoped ephemerality.
    private func relaySessionMessage(
        from senderID: UUID, sessionID: UUID, body: String, clientMessageID: UUID,
        dictated: Bool?
    ) async throws {
        guard let session = try await SessionModel.find(sessionID, on: db),
              session.includes(senderID), session.endedAt == nil
        else {
            await connections.send(.error("No such session."), to: senderID)
            return
        }
        let message = ChatMessage(
            id: UUID(), sessionID: sessionID, senderID: senderID, body: body, sentAt: Date(),
            dictated: dictated)
        for participant in session.participants where participant != senderID {
            await connections.send(.message(message), to: participant)
        }
        await connections.send(
            .messageSent(clientMessageID: clientMessageID, message: message), to: senderID)
    }

    func sessionInfo(_ session: SessionModel, on db: Database) async throws -> SessionInfo {
        let users = try await UserModel.query(on: db)
            .filter(\.$id ~~ session.participants)
            .all()
        return SessionInfo(session: session.dto, participants: users.map(\.dto))
    }

    private func openGroupSessions(of userID: UUID) async throws -> [SessionModel] {
        try await SessionModel.query(on: db)
            .filter(\.$endedAt == nil)
            .all()
            .filter { $0.isGroup && $0.includes(userID) }
    }

    // MARK: - Sessions

    func openSession(between a: UUID, and b: UUID) async throws -> SessionModel {
        let query = SessionModel.query(on: db)
            .filter(\.$endedAt == nil)
            .group(.or) { or in
                or.group(.and) { $0.filter(\.$participantA == a).filter(\.$participantB == b) }
                or.group(.and) { $0.filter(\.$participantA == b).filter(\.$participantB == a) }
            }
        if let existing = try await query.first() {
            return existing
        }
        let session = SessionModel(participants: [a, b])
        try await session.save(on: db)
        return session
    }

    /// Either party going offline ends a 1:1 session for both (spec §2, §6).
    /// Group sessions outlive individual members' presence in v1.
    private func closeOpenSessions(of userID: UUID) async throws {
        let open = try await SessionModel.query(on: db)
            .filter(\.$endedAt == nil)
            .all()
            .filter { !$0.isGroup && $0.includes(userID) }
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

    /// Everyone who renders this user right now: accepted buddies plus
    /// co-participants of open group sessions, who may not be buddies at all.
    func fanOutAvatar(_ avatar: Avatar, of userID: UUID) async {
        var recipients = Set((try? await acceptedBuddyIDs(of: userID)) ?? [])
        for session in (try? await openGroupSessions(of: userID)) ?? [] {
            recipients.formUnion(session.participants)
        }
        recipients.remove(userID)
        for id in recipients {
            await connections.send(.avatarChanged(userID: userID, avatar: avatar), to: id)
        }
    }
}
