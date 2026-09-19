import Fluent
import Foundation
import TotemKit
import Vapor

/// The stateful WebSocket gateway: presence transitions, heartbeats, peer
/// introductions, sittings and bots. Conversation content never passes through
/// it; that travels peer to peer.
struct GatewayController {
    let app: Application
    let connections: ConnectionManager
    let pusher: Pusher
    let bots: BotRegistry

    var presence: PresenceStore { PresenceStore(redis: app.redis) }
    var sittings: SittingStore { SittingStore(redis: app.redis) }
    var db: Database { app.db }

    /// Built per use: the dispatcher needs a way back in to fan out the reply,
    /// and capturing a copy of this value type is cheap and cycle-free.
    private var botDispatcher: BotDispatcher {
        let gateway = self
        return BotDispatcher(registry: bots, app: app) { botID, sessionID, text in
            await gateway.sendBotMessage(botID: botID, sessionID: sessionID, text: text)
        }
    }

    func handleUpgrade(req: Request, ws: WebSocket) async {
        guard let user = req.auth.get(UserModel.self), let userID = user.id else {
            try? await ws.close(code: .policyViolation)
            return
        }
        let generation = await connections.register(ws, for: userID)
        // A socket this one replaced may have left a chat on screen.
        await stopViewing(userID)

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

    /// Turns silent TTL expiry into a real offline transition. A suspended iOS
    /// app never closes its socket: heartbeats stop, the Redis key expires, and
    /// nothing else would notice.
    func startLivenessSweep() {
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                for userID in await self.connections.connectedUserIDs() {
                    let current = try? await self.presence.get(for: userID)
                    if current?.state ?? .offline == .offline {
                        await self.reap(userID)
                        await self.goOffline(userID: userID)
                    }
                }
            }
        }
    }

    /// Pushes a new request to the target's socket, falling back to APNs when
    /// the socket does not answer a ping. Verified off the request path, since
    /// the ping costs 3s.
    func buddyRequestReceived(by targetID: UUID, from user: User) async {
        await connections.send(.buddyRequest, to: targetID)
        let (connections, pusher) = (self.connections, self.pusher)
        Task {
            guard await !connections.verifyAlive(targetID) else { return }
            await pusher.buddyRequested(from: user, to: targetID)
        }
    }

    /// Both welcome snapshots predate the buddyship, so each party is sent the
    /// other's current presence. Only the requester is learning something they
    /// did not do themselves, so they also get the APNs fallback.
    func buddyshipFormed(accepter: UUID, accepterHandle: String, requester: UUID) async {
        // A derived ID on the wire cannot be reversed into its participants,
        // so the row has to exist before anyone can name it.
        do {
            _ = try await conversation(for: [accepter, requester])
        } catch {
            app.logger.report(error: error)
        }
        do {
            await connections.send(
                .presence(userID: requester, presence: try await presence.get(for: requester)),
                to: accepter)
            await connections.send(
                .presence(userID: accepter, presence: try await presence.get(for: accepter)),
                to: requester)
        } catch {
            app.logger.report(error: error)
        }
        let (connections, pusher) = (self.connections, self.pusher)
        Task {
            guard await !connections.verifyAlive(requester) else { return }
            await pusher.buddyRequestAccepted(
                by: accepter, handle: accepterHandle, to: requester)
        }
    }

    // MARK: - Lifecycle

    private func signOn(user: UserModel, userID: UUID) async {
        do {
            // Preserve an existing away state on reconnect; otherwise online.
            let existing = try await presence.get(for: userID)
            // Only an offline-to-online transition is a sign-on; a reconnect
            // within the presence TTL is not.
            let wasOffline = existing.state == .offline
            // A message-less away is the server's unreachable mark, which
            // being back answers. An away the user wrote survives the reconnect.
            let current = wasOffline || existing.isUnreachableMark
                ? Presence(state: .online) : existing
            try await presence.set(current, for: userID)
            try? await touchLastSeen(userID)

            let buddyIDs = try await acceptedBuddyIDs(of: userID)
            var snapshot: [String: Presence] = [:]
            for id in buddyIDs {
                snapshot[id.uuidString] = try await presence.get(for: id)
            }
            var sessionInfos: [SessionInfo] = []
            for (id, sitting) in try await sittings.all()
            where sitting.participants.count > 2 && sitting.participants.contains(userID) {
                sessionInfos.append(try await sessionInfo(
                    id: id, participants: sitting.participants,
                    startedAt: sitting.startedAt, on: db))
            }
            let avatar = user.dto.avatar
            await connections.send(
                .welcome(self_: current, buddies: snapshot, sessions: sessionInfos,
                         freshSignOn: wasOffline, selfAvatar: avatar,
                         bots: await bots.all(),
                         latestBuild: Environment.get("LATEST_CLIENT_BUILD")),
                to: userID)
            // Viewing and endpoints are socket state, not in the welcome, so a
            // client back from a drop is told afresh.
            for (viewerID, conversationID) in await connections.viewers(of: userID) {
                await connections.send(
                    .viewing(conversationID: conversationID, userID: viewerID, viewing: true),
                    to: userID)
            }
            for peerID in await renderers(of: userID) {
                if let ticket = await connections.endpoint(of: peerID) {
                    await connections.send(.endpoint(userID: peerID, ticket: ticket), to: userID)
                }
            }
            await fanOut(.presence(userID: userID, presence: current), toBuddiesOf: userID)
            // Buddies' cached lists can predate this user publishing an avatar.
            if let avatar {
                await fanOutAvatar(avatar, of: userID)
            }
            if wasOffline {
                let pusher = self.pusher
                let connections = self.connections
                Task {
                    await pusher.buddySignedOn(userID, buddyIDs: buddyIDs, connections: connections)
                    await pusher.refreshBadges(of: buddyIDs)
                }
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    /// Non-deliberate drop: holds the last presence for the grace window so a
    /// user in a tunnel does not flap to offline.
    private func handleClose(userID: UUID, ws: WebSocket, generation: Int) async {
        if await connections.unregister(userID, ifStill: ws) {
            await stopViewing(userID)
        }
        await goOffline(userID: userID, afterGraceFrom: generation)
    }

    /// Force-closes a silent socket.
    private func reap(_ userID: UUID) async {
        await connections.expire(userID)
        await stopViewing(userID)
    }

    /// Goes offline once the grace elapses, unless the user came back. Any
    /// reconnect or `expire` bumps the generation and makes this a no-op.
    private func goOffline(userID: UUID, afterGraceFrom generation: Int) async {
        try? await Task.sleep(for: .seconds(PresenceStore.ttlSeconds))
        guard await connections.generation(of: userID) == generation,
              await !connections.isConnected(userID)
        else { return }
        await goOffline(userID: userID)
    }

    /// Marks a user away rather than offline after a failed liveness check. A
    /// failed ping proves only that they are unreachable now, and offline is
    /// the expensive transition: transcripts cleared, sittings ended, a sign-on
    /// alert to every buddy on the way back.
    private func markUnreachable(_ userID: UUID) async {
        // A half-open socket never fires onClose, so reap it here and start
        // the offline countdown its own close would have started.
        if await connections.isConnected(userID) {
            await reap(userID)
            let generation = await connections.generation(of: userID)
            Task { await goOffline(userID: userID, afterGraceFrom: generation) }
        }
        do {
            let current = try await presence.get(for: userID)
            // An away the user wrote outranks anything the server inferred.
            guard current.state != .offline, current.state != .away else { return }
            guard try await presence.annotate(.unreachable, for: userID) else { return }
            await fanOut(.presence(userID: userID, presence: .unreachable), toBuddiesOf: userID)
        } catch {
            app.logger.report(error: error)
        }
    }

    /// Stamps evidence the user is here now. Not called from `goOffline`,
    /// which can run minutes after the last real sign of life.
    private func touchLastSeen(_ userID: UUID) async throws {
        try await UserModel.query(on: db).filter(\.$id == userID)
            .set(\.$lastSeenAt, to: Date()).update()
    }

    private func goOffline(userID: UUID) async {
        do {
            try await presence.markOffline(for: userID)
            await fanOut(.presence(userID: userID, presence: .offline), toBuddiesOf: userID)
            let pusher = self.pusher
            let buddyIDs = try await acceptedBuddyIDs(of: userID)
            Task { await pusher.refreshBadges(of: buddyIDs) }
            await endSittings(involving: userID)
        } catch {
            app.logger.report(error: error)
        }
    }

    /// Ends every sitting left with fewer than two participants online. A
    /// member inside the reconnect grace window still counts as present.
    private func endSittings(involving userID: UUID) async {
        let all = (try? await sittings.all()) ?? [:]
        for (conversationID, sitting) in all where sitting.participants.contains(userID) {
            var online = 0
            for participant in sitting.participants {
                let state = (try? await presence.get(for: participant))?.state ?? .offline
                if state != .offline { online += 1 }
            }
            guard online < 2 else { continue }
            try? await sittings.close(conversationID)
            for participant in sitting.participants where participant != userID {
                await connections.send(.sessionClosed(sessionID: conversationID), to: participant)
            }
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
                try await touchLastSeen(userID)

            case .setPresence(let state, let awayMessage):
                guard state != .offline else {
                    try? await touchLastSeen(userID)
                    await goOffline(userID: userID)
                    return
                }
                let message = awayMessage.map { String($0.prefix(Limits.awayMessageMaxLength)) }
                let updated = Presence(state: state, awayMessage: message)
                try await presence.set(updated, for: userID)
                await fanOut(.presence(userID: userID, presence: updated), toBuddiesOf: userID)

            case .signOff:
                try? await touchLastSeen(userID)
                await goOffline(userID: userID)

            // The server only introduces peers, to the people who render this user.
            case .announceEndpoint(let ticket):
                guard ticket.count <= Limits.endpointTicketMaxLength else { return }
                await connections.setEndpoint(ticket, for: userID)
                for id in await renderers(of: userID) {
                    await connections.send(.endpoint(userID: userID, ticket: ticket), to: id)
                }

            // Only a 1:1 has a peer to tell; a group counts as nothing on screen.
            case .viewing(let conversationID):
                var target: ConnectionManager.Viewing?
                if let conversationID,
                   let conversation = try await usableConversation(conversationID, by: userID),
                   !conversation.isGroup {
                    target = .init(conversationID: conversationID,
                                   peerID: conversation.peer(of: userID))
                }
                let previous = await connections.setViewing(target, for: userID)
                await announceViewing(of: userID, from: previous, to: target)

            // The humans already have the message over their peer links.
            case .botQuery(let conversationID, let body, let context):
                guard let conversation = try await usableConversation(conversationID, by: userID)
                else { return }
                // The reply only fans out into a live sitting, and the
                // client's `conversationActive` may not have arrived yet.
                if !conversation.isGroup {
                    try await sittings.open(
                        conversationID, participants: conversation.participants, at: Date())
                }
                botDispatcher.dispatch(body: body, from: userID, sessionID: conversationID,
                                       context: context)

            // The client's report is evidence; the server's ping is the judgement.
            case .unreachable(let peerID):
                guard try await areAcceptedBuddies(userID, peerID),
                      await !connections.verifyAlive(peerID)
                else { return }
                await markUnreachable(peerID)

            // A push only for someone actually gone; the throttle lives in the pusher.
            case .knock(let peerID):
                guard try await areAcceptedBuddies(userID, peerID),
                      try await presence.get(for: peerID).state == .offline
                else { return }
                Task { await pusher.knock(from: userID, to: peerID) }

            // Traffic opens a pair's sitting. A group's was opened by creating it.
            case .conversationActive(let conversationID):
                guard let conversation = try await usableConversation(conversationID, by: userID),
                      !conversation.isGroup
                else { return }
                try await sittings.open(
                    conversationID, participants: conversation.participants, at: Date())
            }
        } catch {
            app.logger.report(error: error)
            await connections.send(.error("Internal error."), to: userID)
        }
    }

    /// Fans a bot's answer out to everyone in the conversation, the tagger
    /// included, keyed by the conversation ID that clients render by.
    private func sendBotMessage(botID: UUID, sessionID: UUID, text: String) async {
        // Everyone may have signed off during the round trip, ending the sitting.
        guard let conversation = try? await ConversationModel.find(sessionID, on: db),
              (try? await sittings.get(sessionID)) != nil
        else { return }
        let message = ChatMessage(
            id: UUID(), sessionID: sessionID, senderID: botID, body: text, sentAt: Date())
        for participant in conversation.participants {
            await connections.send(
                .botMessage(conversationID: sessionID, message: message), to: participant)
        }
    }

    func sessionInfo(id: UUID, participants: [UUID], startedAt: Date,
                     on db: Database) async throws -> SessionInfo {
        let users = try await UserModel.query(on: db)
            .filter(\.$id ~~ participants)
            .all()
        return SessionInfo(
            session: ChatSession(id: id, participantIDs: participants, startedAt: startedAt),
            participants: users.map(\.dto))
    }

    /// The membership check behind every frame naming a conversation ID, since
    /// a derived ID is computable by anyone and so is not a capability. A group
    /// also needs a live sitting; a pair needs only the buddyship, because its
    /// ephemera can precede any message traffic.
    private func usableConversation(_ id: UUID, by userID: UUID) async throws -> ConversationModel? {
        guard let conversation = try await ConversationModel.find(id, on: db),
              conversation.includes(userID)
        else { return nil }
        if conversation.isGroup {
            guard try await sittings.get(id) != nil else { return nil }
        } else {
            guard try await areAcceptedBuddies(userID, conversation.peer(of: userID))
            else { return nil }
        }
        return conversation
    }

    // MARK: - Viewing

    private func stopViewing(_ userID: UUID) async {
        let previous = await connections.setViewing(nil, for: userID)
        await announceViewing(of: userID, from: previous, to: nil)
    }

    /// The peer being left is told before the peer being joined; a resend of
    /// the same target says nothing.
    private func announceViewing(of userID: UUID, from previous: ConnectionManager.Viewing?,
                                 to current: ConnectionManager.Viewing?) async {
        guard previous != current else { return }
        if let previous {
            await connections.send(
                .viewing(conversationID: previous.conversationID, userID: userID, viewing: false),
                to: previous.peerID)
        }
        if let current {
            await connections.send(
                .viewing(conversationID: current.conversationID, userID: userID, viewing: true),
                to: current.peerID)
        }
    }

    // MARK: - Conversations

    /// Find-or-create for the combination's one permanent row.
    func conversation(for participants: [UUID]) async throws -> ConversationModel {
        let id = ConversationID.derive(participants)
        if let existing = try await ConversationModel.find(id, on: db) {
            return existing
        }
        let conversation = ConversationModel(participants: participants)
        do {
            try await conversation.create(on: db)
            return conversation
        } catch {
            if let existing = try await ConversationModel.find(id, on: db) {
                return existing
            }
            throw error
        }
    }

    // MARK: - Buddies

    private func acceptedBuddyIDs(of userID: UUID) async throws -> [UUID] {
        try await BuddyModel.acceptedBuddyIDs(of: userID, on: db)
    }

    func areAcceptedBuddies(_ a: UUID, _ b: UUID) async throws -> Bool {
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

    /// Everyone who renders this user: accepted buddies plus co-participants of
    /// live group sittings, who need not be buddies.
    private func renderers(of userID: UUID) async -> Set<UUID> {
        var recipients = Set((try? await acceptedBuddyIDs(of: userID)) ?? [])
        for (_, sitting) in (try? await sittings.all()) ?? [:]
        where sitting.participants.count > 2 && sitting.participants.contains(userID) {
            recipients.formUnion(sitting.participants)
        }
        recipients.remove(userID)
        return recipients
    }

    func fanOutAvatar(_ avatar: Avatar, of userID: UUID) async {
        for id in await renderers(of: userID) {
            await connections.send(.avatarChanged(userID: userID, avatar: avatar), to: id)
        }
    }
}
