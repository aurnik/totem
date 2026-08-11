import Fluent
import Foundation
import TotemKit
import Vapor

/// The stateful WebSocket gateway: presence transitions, heartbeats, message
/// relay, and session auto-archive (spec §3, §4).
struct GatewayController {
    let app: Application
    let connections: ConnectionManager
    let stages: StageStore
    let pusher: Pusher
    let bots: BotRegistry

    var presence: PresenceStore { PresenceStore(redis: app.redis) }
    var sittings: SittingStore { SittingStore(redis: app.redis) }
    var db: Database { app.db }

    /// Built per use rather than stored: the dispatcher needs a way back in to
    /// fan out the reply, and the gateway is a value type, so capturing a copy
    /// is both cheap and cycle-free.
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
        await connections.send(.buddyRequest, to: targetID)
        let (connections, pusher) = (self.connections, self.pusher)
        Task {
            guard await !connections.verifyAlive(targetID) else { return }
            await pusher.buddyRequested(from: user, to: targetID)
        }
    }

    /// After a mutual accept, each party's welcome snapshot predates the
    /// buddyship — push each one's current presence to the other. Only the
    /// requester is learning something they didn't do themselves, so they get
    /// the same live-socket-then-APNs treatment the request itself got.
    func buddyshipFormed(accepter: UUID, accepterHandle: String, requester: UUID) async {
        // The pair's conversation exists from the moment it *could* be used:
        // a derived ID arriving on the wire can't be reversed into its
        // participants, so the row must predate anyone naming it.
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
            // Only a genuine offline→online transition is a sign-on; socket
            // reconnects within the presence TTL are not.
            let wasOffline = existing.state == .offline
            // A message-less away is the one the server set on their behalf
            // when it found them unreachable — clients can only go away by
            // writing a message, so nothing else produces this shape. Being
            // back is the answer to it, so it clears; a real away message is
            // the user's own and survives the reconnect.
            let current = wasOffline || existing.isUnreachableMark
                ? Presence(state: .online) : existing
            try await presence.set(current, for: userID)

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
        await goOffline(userID: userID, afterGraceFrom: generation)
    }

    /// Offline once the grace elapses, unless they came back. The generation
    /// they were at when we started waiting is the test: any reconnect — or any
    /// `expire` that supersedes this wait with its own — bumps it, and this
    /// no-ops.
    private func goOffline(userID: UUID, afterGraceFrom generation: Int) async {
        try? await Task.sleep(for: .seconds(PresenceStore.ttlSeconds))
        guard await connections.generation(of: userID) == generation,
              await !connections.isConnected(userID)
        else { return }
        await goOffline(userID: userID)
    }

    /// A failed liveness check is certain evidence we can't reach them *now*,
    /// and only weak evidence that they left — a wifi handoff looks identical
    /// to a walk-out. So it marks them away rather than crossing them offline:
    /// going offline is the expensive transition (their transcripts cleared,
    /// 1:1 sessions archived, a sign-on alert to every buddy on the way back),
    /// and the grace period exists precisely so a tunnel doesn't pay it. This
    /// tells whoever just tried to send them something what their buddy list
    /// was contradicting, and costs nothing if they walk straight back in.
    private func markUnreachable(_ userID: UUID) async {
        // A half-open socket never fires onClose, so a dead-but-registered one
        // is reaped here or not at all. Reaping supersedes the countdown its
        // own close would have started, so this takes over that duty.
        if await connections.isConnected(userID) {
            await connections.expire(userID)
            let generation = await connections.generation(of: userID)
            Task { await goOffline(userID: userID, afterGraceFrom: generation) }
        }
        do {
            let current = try await presence.get(for: userID)
            // Offline needs no correction, and an away they wrote themselves
            // outranks anything the server inferred.
            guard current.state != .offline, current.state != .away else { return }
            guard try await presence.annotate(.unreachable, for: userID) else { return }
            await fanOut(.presence(userID: userID, presence: .unreachable), toBuddiesOf: userID)
        } catch {
            app.logger.report(error: error)
        }
    }

    private func goOffline(userID: UUID) async {
        do {
            try await presence.markOffline(for: userID)
            await fanOut(.presence(userID: userID, presence: .offline), toBuddiesOf: userID)
            await endSittings(involving: userID)
            // The peer clears its own copy off the offline presence frame, so
            // this needs no fan-out of its own.
            await stages.clearPairs(involving: userID)
            // A group game does need one: nothing else tells the people still
            // in the chat that a player just left. Unattributed, so it posts no
            // notice — the sign-off notice already says what happened.
            for (conversationID, participants) in await stages.clearGames(involving: userID) {
                for participant in participants {
                    await connections.send(
                        .stage(conversationID: conversationID, senderID: nil, stage: nil),
                        to: participant)
                }
            }
        } catch {
            app.logger.report(error: error)
        }
    }

    /// A sitting ends when fewer than two participants remain online: for a
    /// pair that's either party leaving — the old 1:1 auto-archive — and for a
    /// group it's the single-sitting rule, since a conversation one person is
    /// sitting in alone isn't one. Presence is the judge, so a member inside
    /// the reconnect grace window still counts as present and keeps the
    /// sitting alive, exactly as they keep their own transcripts.
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
            await stages.clear(conversationID)
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

            case .sendMessage(let recipientID, let body, let clientMessageID, let dictated,
                              let botContext):
                try await relayMessage(
                    from: userID, to: recipientID, body: body,
                    clientMessageID: clientMessageID, dictated: dictated,
                    botContext: botContext)

            case .sendSessionMessage(let sessionID, let body, let clientMessageID, let dictated,
                                     let botContext):
                try await relaySessionMessage(
                    from: userID, sessionID: sessionID, body: body,
                    clientMessageID: clientMessageID, dictated: dictated,
                    botContext: botContext)

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
                      let conversation = try await openConversation(sessionID, memberedBy: userID)
                else { return }
                await send(.audio(conversationID: sessionID, senderID: userID, chunk: chunk),
                           toParticipantsOf: conversation, except: userID)

            case .setAudioMuted(let recipientID, let muted):
                guard try await areAcceptedBuddies(userID, recipientID) else { return }
                await connections.send(
                    .audioMuted(conversationID: userID, userID: userID, muted: muted),
                    to: recipientID)

            case .setSessionAudioMuted(let sessionID, let muted):
                guard let conversation = try await openConversation(sessionID, memberedBy: userID)
                else { return }
                await send(.audioMuted(conversationID: sessionID, userID: userID, muted: muted),
                           toParticipantsOf: conversation, except: userID)

            case .stageAction(let conversationID, let action, let expectedVersion):
                try await applyStageAction(action, expectedVersion: expectedVersion,
                                           in: conversationID, from: userID)

            case .requestStage(let conversationID):
                guard let conversation = try await stageConversation(conversationID, for: userID),
                      let key = stageKey(conversation, actedBy: userID)
                else { return }
                await connections.send(
                    .stage(conversationID: conversationID, senderID: nil, stage: await stages.get(key)),
                    to: userID)

            case .closeStage(let conversationID):
                guard let conversation = try await stageConversation(conversationID, for: userID),
                      let key = stageKey(conversation, actedBy: userID)
                else { return }
                await stages.clear(key)
                await sendStage(nil, in: conversation, from: userID, actedBy: userID)
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
        dictated: Bool?, botContext: [BotContextMessage]?
    ) async throws {
        guard try await areAcceptedBuddies(senderID, recipientID) else {
            await connections.send(.error("Not buddies."), to: senderID)
            return
        }
        // Sending is the moment liveness matters: ping-verify a nominally
        // connected recipient so a suspended app is discovered now rather
        // than when the sweep catches it.
        guard await connections.verifyAlive(recipientID) else {
            await markUnreachable(recipientID)
            await connections.send(.error("Message not delivered — they're away."), to: senderID)
            return
        }
        let conversation = try await conversation(for: [senderID, recipientID])
        let conversationID = try conversation.requireID()
        // Traffic opens the sitting; its death on either party's sign-off is
        // what tells the peer to drop the conversation's live ephemera.
        try await sittings.open(
            conversationID, participants: conversation.participants, at: Date())
        let message = ChatMessage(
            id: UUID(), sessionID: conversationID,
            senderID: senderID, body: body, sentAt: Date(), dictated: dictated)
        await connections.send(.message(message), to: recipientID)
        await connections.send(
            .messageSent(clientMessageID: clientMessageID, message: message), to: senderID)
        // A refused message never reaches a bot — the guards above mean this
        // only runs for a message that was actually delivered.
        botDispatcher.dispatch(body: body, from: senderID, sessionID: conversationID,
                               context: botContext)
    }

    /// Group message: relay to every connected member, store nothing.
    /// Offline members miss it — sitting-scoped ephemerality.
    private func relaySessionMessage(
        from senderID: UUID, sessionID: UUID, body: String, clientMessageID: UUID,
        dictated: Bool?, botContext: [BotContextMessage]?
    ) async throws {
        guard let conversation = try await openConversation(sessionID, memberedBy: senderID) else {
            await connections.send(.error("No such session."), to: senderID)
            return
        }
        let message = ChatMessage(
            id: UUID(), sessionID: sessionID, senderID: senderID, body: body, sentAt: Date(),
            dictated: dictated)
        await send(.message(message), toParticipantsOf: conversation, except: senderID)
        await connections.send(
            .messageSent(clientMessageID: clientMessageID, message: message), to: senderID)
        botDispatcher.dispatch(body: body, from: senderID, sessionID: sessionID,
                               context: botContext)
    }

    /// A bot's answer, fanned out to everyone in the conversation — the person
    /// who tagged it included, unlike a relayed human message, since the bot's
    /// reply is new to them too.
    ///
    /// Each recipient gets it keyed the way they render the conversation: the
    /// session ID in a group, the other party's user ID in a 1:1. A bot isn't a
    /// participant, so clients can't infer that from the sender the way they do
    /// for `message`.
    private func sendBotMessage(botID: UUID, sessionID: UUID, text: String) async {
        // Everyone may have signed off during the round trip, which ends the
        // sitting. Nobody is listening, so there is nothing to say.
        guard let conversation = try? await ConversationModel.find(sessionID, on: db),
              (try? await sittings.get(sessionID)) != nil
        else { return }
        let message = ChatMessage(
            id: UUID(), sessionID: sessionID, senderID: botID, body: text, sentAt: Date())
        let participants = conversation.participants
        for participant in participants {
            let conversationID = conversation.isGroup
                ? sessionID
                : (participants.first { $0 != participant } ?? participant)
            await connections.send(
                .botMessage(conversationID: conversationID, message: message), to: participant)
        }
    }

    // MARK: - Stage

    /// A stage lives in one of two shapes, and the wire doesn't say which:
    /// clients send the same conversation key they render by, so a live group
    /// wins if the ID names one the sender belongs to, and otherwise it's
    /// read as a buddy's user ID.
    private enum StageConversation {
        case group(ConversationModel)
        case pair(peerID: UUID)
    }

    private func stageConversation(_ conversationID: UUID, for userID: UUID) async throws -> StageConversation? {
        if let conversation = try await openConversation(conversationID, memberedBy: userID),
           conversation.isGroup {
            return .group(conversation)
        }
        guard try await areAcceptedBuddies(userID, conversationID) else { return nil }
        return .pair(peerID: conversationID)
    }

    /// The store's key is the derived conversation ID for both shapes — for a
    /// pair it's computed here, since the wire still names the peer instead.
    private func stageKey(_ conversation: StageConversation, actedBy userID: UUID) -> UUID? {
        switch conversation {
        case .group(let conversation): conversation.id
        case .pair(let peerID): ConversationID.derive([userID, peerID])
        }
    }

    private func stageParticipants(_ conversation: StageConversation, actedBy userID: UUID) -> [UUID] {
        switch conversation {
        case .group(let conversation): conversation.participants
        case .pair(let peerID): [userID, peerID]
        }
    }

    /// The server is authoritative: it orders actions, runs the shared reducer,
    /// and echoes the result to everyone including whoever acted — that echo is
    /// their confirmation, so no client applies anything optimistically.
    private func applyStageAction(_ action: StageAction, expectedVersion: Int?,
                                  in conversationID: UUID, from userID: UUID) async throws {
        guard let conversation = try await stageConversation(conversationID, for: userID),
              let key = stageKey(conversation, actedBy: userID)
        else {
            await connections.send(.error("No such conversation."), to: userID)
            return
        }
        let applied = await stages.apply(
            action, by: userID, expectedVersion: expectedVersion, to: key,
            participants: stageParticipants(conversation, actedBy: userID), at: Date())
        switch applied {
        case .updated(let stage):
            await sendStage(stage, in: conversation, from: userID, actedBy: userID)
        case .unchanged:
            break
        case .cleared:
            // Unattributed: the video ran out, nobody closed it, so this posts
            // no notice.
            await sendStage(nil, in: conversation, from: nil, actedBy: userID)
        case .rejected(let current):
            // They acted on a stage that has since moved on. Re-sync them alone
            // and quietly — nobody else's view was wrong.
            await connections.send(
                .stage(conversationID: conversationID, senderID: nil, stage: current), to: userID)
        }
    }

    /// Every recipient gets the stage keyed the way they render it: the session
    /// ID in a group, the other party's user ID in a 1:1.
    private func sendStage(_ stage: Stage?, in conversation: StageConversation,
                           from senderID: UUID?, actedBy userID: UUID) async {
        switch conversation {
        case .group(let group):
            guard let conversationID = try? group.requireID() else { return }
            for participant in group.participants {
                await connections.send(
                    .stage(conversationID: conversationID, senderID: senderID, stage: stage),
                    to: participant)
            }
        case .pair(let peerID):
            await connections.send(
                .stage(conversationID: peerID, senderID: senderID, stage: stage), to: userID)
            await connections.send(
                .stage(conversationID: userID, senderID: senderID, stage: stage), to: peerID)
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

    /// A conversation the user belongs to whose sitting is live. Callers
    /// disagree on whether a miss deserves an error frame — messages answer,
    /// audio stays silent — so this only reports the miss.
    private func openConversation(_ id: UUID, memberedBy userID: UUID) async throws -> ConversationModel? {
        guard let conversation = try await ConversationModel.find(id, on: db),
              conversation.includes(userID),
              try await sittings.get(id) != nil
        else { return nil }
        return conversation
    }

    private func send(_ frame: ServerFrame, toParticipantsOf conversation: ConversationModel,
                      except senderID: UUID) async {
        for participant in conversation.participants where participant != senderID {
            await connections.send(frame, to: participant)
        }
    }

    // MARK: - Conversations

    /// Find-or-create for the combination's one permanent row. A lost create
    /// race is indistinguishable from the row having existed all along.
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
        try await BuddyModel.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$status == .accepted)
            .all()
            .map { $0.$buddy.id }
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

    /// Everyone who renders this user right now: accepted buddies plus
    /// co-participants of live group sittings, who may not be buddies at all.
    func fanOutAvatar(_ avatar: Avatar, of userID: UUID) async {
        var recipients = Set((try? await acceptedBuddyIDs(of: userID)) ?? [])
        for (_, sitting) in (try? await sittings.all()) ?? [:]
        where sitting.participants.count > 2 && sitting.participants.contains(userID) {
            recipients.formUnion(sitting.participants)
        }
        recipients.remove(userID)
        for id in recipients {
            await connections.send(.avatarChanged(userID: userID, avatar: avatar), to: id)
        }
    }
}
