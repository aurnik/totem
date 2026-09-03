import Foundation
import IrohLib
import TotemKit

/// Everything conversation-shaped travels here, never through the server.
/// Each signed-on device runs an iroh endpoint with one QUIC connection per
/// peer: voice rides it as datagrams, one Opus packet each, and everything
/// that must arrive in order — messages, typing, the stage — as
/// length-prefixed `PeerFrame`s on a stream. The server only introduces
/// people. Every ticket it relays arrives with the user it belongs to, and
/// that map is the whole access control: a connection from an endpoint the
/// server never named is refused, and every inbound frame is stamped with
/// the user the connection was accepted for.
///
/// Frames go on a unidirectional stream each way rather than one
/// bidirectional stream: a QUIC stream doesn't exist at the far end until
/// bytes flow on it, so with a shared stream the accepting side could say
/// nothing until the opener spoke first. Each side opens its own on first
/// use and reads whatever the other opens.
///
/// Safe from any thread — the capture tap sends from the audio thread and
/// the model drives everything else from the main actor.
final class PeerLink: @unchecked Sendable {
    struct AudioFrame: Sendable {
        let senderID: UUID
        let conversationID: UUID
        let packet: Data
    }

    struct Inbound: Sendable {
        let senderID: UUID
        let frame: PeerFrame
    }

    /// How a peer is reached right now. A link opens on the relay and moves
    /// to a direct path once hole punching lands, usually within seconds.
    enum LinkState: Sendable {
        case connecting, relay, direct
    }

    enum LinkError: Error {
        /// No link came up in time — the peer is unreachable, or the server
        /// never introduced them.
        case noLink
        case stopped
        /// The write couldn't drain inside the deadline. A completed QUIC
        /// write means the bytes reached the local send buffer, not the peer,
        /// so a peer that stops acknowledging — a phone whose radio just went
        /// off — lets the flow-control window fill and then `writeAll` blocks
        /// for the whole idle timeout. That is a failed delivery now, not in
        /// thirty seconds.
        case writeStalled
    }

    /// A stalled write is abandoned after this. It sits just under the
    /// delivery timeout the model reports on, so "not delivered" is the
    /// write giving up, not the ack.
    static let writeTimeout: Duration = .seconds(4)

    private static let alpn = Data("totem/peer/1".utf8)
    /// Conversation ID, then a per-sender sequence number, ahead of the packet.
    private static let headerBytes = 16 + 4
    /// How long a frame waits for a link before it's reported undelivered.
    /// Long enough for a dial through the relay, short enough that "not
    /// delivered" still arrives while the sender is looking.
    static let linkTimeout: Duration = .seconds(5)
    private static let keyURL = URL.applicationSupportDirectory
        .appendingPathComponent("voice.key")

    private let lock = NSLock()
    private var endpoint: Endpoint?
    private var acceptLoop: Task<Void, Never>?
    private var addrPoll: Task<Void, Never>?
    private(set) var ticket: String?
    /// Where each introduced user is dialled, and which endpoint identity is
    /// theirs — the accept side's allow-list.
    private var addresses: [UUID: EndpointAddr] = [:]
    private var users: [String: UUID] = [:]
    private var connections: [UUID: Connection] = [:]
    private var outbound: [UUID: Outbound] = [:]
    private var dialing: Set<UUID> = []
    /// Frames waiting for a link to a user to come up.
    private var waiting: [UUID: [Waiter]] = [:]
    /// Peers whose link is kept up: dialled as soon as they're introduced,
    /// and again whenever the link drops.
    private var warm: Set<UUID> = []
    private var recipients: [UUID: Set<UUID>] = [:]
    private var sequence: UInt32 = 0
    private var lastSequence: [UUID: UInt32] = [:]
    private let onTicket: @Sendable (String) -> Void
    private let onAudio: @Sendable (AudioFrame) -> Void
    private let onFrame: @Sendable (Inbound) -> Void
    /// Nil when the link to that user is gone.
    private let onLink: @Sendable (UUID, LinkState?) -> Void

    init(onTicket: @escaping @Sendable (String) -> Void,
         onAudio: @escaping @Sendable (AudioFrame) -> Void,
         onFrame: @escaping @Sendable (Inbound) -> Void,
         onLink: @escaping @Sendable (UUID, LinkState?) -> Void) {
        self.onTicket = onTicket
        self.onAudio = onAudio
        self.onFrame = onFrame
        self.onLink = onLink
    }

    // MARK: - Lifecycle

    /// Binds under this device's persistent identity and waits until the
    /// endpoint is reachable — `online()` is what registers it with a relay;
    /// without it the ticket carries no relay and nobody off the LAN can dial.
    func start() async {
        do {
            let endpoint = try await Endpoint.bind(options: EndpointOptions(
                preset: presetN0(), secretKey: Self.secretKey().toBytes(), alpns: [Self.alpn]))
            lock.withLock { self.endpoint = endpoint }
            await endpoint.online()
            publishTicket(for: endpoint.addr())
            // iroh 1.1.0's `watchAddr` panics ("no reactor running") when
            // called from Swift — fixed upstream after the release, so until
            // the next one the addresses are polled. A network change is
            // re-announced within this interval.
            addrPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    self?.publishTicket(for: endpoint.addr())
                }
            }
            acceptLoop = Task { [weak self] in
                while let incoming = try? await endpoint.acceptNext() {
                    guard let self else { return }
                    Task { await self.adopt(incoming) }
                }
            }
        } catch {
            print("peer endpoint failed to start: \(error)")
        }
    }

    func stop() async {
        acceptLoop?.cancel()
        acceptLoop = nil
        addrPoll?.cancel()
        addrPoll = nil
        let (endpoint, open, waiters) = lock.withLock {
            defer {
                self.endpoint = nil
                ticket = nil
                addresses = [:]
                users = [:]
                connections = [:]
                outbound = [:]
                waiting = [:]
                warm = []
                recipients = [:]
                lastSequence = [:]
            }
            return (self.endpoint, Array(connections.values), waiting.values.flatMap { $0 })
        }
        for waiter in waiters {
            waiter.resume(throwing: LinkError.stopped)
        }
        for connection in open {
            try? connection.close(errorCode: 0, reason: Data())
        }
        try? await endpoint?.close()
    }

    private func publishTicket(for addr: EndpointAddr) {
        guard let ticket = try? EndpointTicket.fromAddr(addr: addr).description else { return }
        let changed = lock.withLock {
            defer { self.ticket = ticket }
            return self.ticket != ticket
        }
        if changed { onTicket(ticket) }
    }

    private static func secretKey() -> SecretKey {
        if let raw = try? Data(contentsOf: keyURL), let key = try? SecretKey.fromBytes(bytes: raw) {
            return key
        }
        let key = SecretKey.generate()
        try? FileManager.default.createDirectory(
            at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? key.toBytes().write(to: keyURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        return key
    }

    // MARK: - Peers

    /// The server introduced (or re-introduced) a user. Dialled right away if
    /// their link is wanted: a conversation with them is open, or voice is
    /// already going their way.
    func setPeer(_ userID: UUID, ticket: String) {
        guard let addr = try? EndpointTicket.fromString(str: ticket).endpointAddr() else { return }
        let wanted = lock.withLock {
            addresses[userID] = addr
            users[addr.id().description] = userID
            return warm.contains(userID) || waiting[userID] != nil
                || recipients.values.contains { $0.contains(userID) }
        }
        if wanted { dial(userID) }
    }

    func removePeer(_ userID: UUID) {
        let (connection, waiters) = lock.withLock {
            if let addr = addresses.removeValue(forKey: userID) {
                users[addr.id().description] = nil
            }
            lastSequence[userID] = nil
            outbound[userID] = nil
            warm.remove(userID)
            return (connections.removeValue(forKey: userID),
                    waiting.removeValue(forKey: userID) ?? [])
        }
        for waiter in waiters {
            waiter.resume(throwing: LinkError.noLink)
        }
        try? connection?.close(errorCode: 0, reason: Data())
    }

    /// The peers whose links stay up while a conversation with them is open,
    /// so the first keystroke doesn't wait on a handshake. Absolute, like
    /// everything else here: the model recomputes the whole set.
    func keepWarm(_ userIDs: Set<UUID>) {
        lock.withLock { warm = userIDs }
        for userID in userIDs { dial(userID) }
    }

    /// Who a conversation's voice packets go to. Dials everyone not yet
    /// connected so the first packet doesn't wait on a handshake.
    func setRecipients(_ userIDs: Set<UUID>, of conversationID: UUID) {
        lock.withLock { recipients[conversationID] = userIDs }
        for userID in userIDs { dial(userID) }
    }

    private func dial(_ userID: UUID) {
        let target: (Endpoint, EndpointAddr)? = lock.withLock {
            guard let endpoint, let addr = addresses[userID],
                  connections[userID] == nil, !dialing.contains(userID)
            else { return nil }
            dialing.insert(userID)
            return (endpoint, addr)
        }
        guard let (endpoint, addr) = target else { return }
        onLink(userID, .connecting)
        Task {
            defer { lock.withLock { _ = dialing.remove(userID) } }
            guard let connection = try? await endpoint.connect(addr: addr, alpn: Self.alpn)
            else {
                if lock.withLock({ connections[userID] == nil }) {
                    onLink(userID, nil)
                    fail(userID, with: LinkError.noLink)
                }
                return
            }
            adopt(connection, from: userID)
        }
    }

    private func adopt(_ incoming: Incoming) async {
        guard let connection = try? await incoming.accept().connect() else { return }
        let userID = lock.withLock { users[connection.remoteId().description] }
        guard let userID else {
            try? connection.close(errorCode: 1, reason: Data("unknown".utf8))
            return
        }
        adopt(connection, from: userID)
    }

    /// Both sides may dial at once; the newest connection carries our sends
    /// and every one is read until it closes.
    private func adopt(_ connection: Connection, from userID: UUID) {
        let waiters = lock.withLock {
            connections[userID] = connection
            outbound[userID] = Outbound(connection)
            return waiting.removeValue(forKey: userID) ?? []
        }
        for waiter in waiters {
            waiter.resume(returning: connection)
        }
        let reading = Task { [weak self] in
            while let datagram = try? await connection.readDatagram() {
                self?.receiveDatagram(datagram, from: userID)
            }
            self?.lost(connection, to: userID)
        }
        Task { [weak self] in
            while let stream = try? await connection.acceptUni() {
                guard let self else { return }
                Task { await self.read(stream, from: userID) }
            }
            self?.lost(connection, to: userID)
        }
        // Whether the link punched through or is riding the relay is worth
        // both showing and logging — it's the one fact that explains voice
        // that sounds fine one minute and choppy the next.
        Task { [weak self] in
            var last: LinkState?
            while !reading.isCancelled, let self, self.lock.withLock({ self.connections[userID] === connection }) {
                let selected = connection.paths().first { $0.isSelected }
                let state: LinkState = selected.map { $0.isIp ? .direct : .relay } ?? .connecting
                if state != last {
                    last = state
                    self.onLink(userID, state)
                    print("peer: \(userID) \(state) \(selected?.remoteAddr ?? "")")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// A connection ended. If it was the one carrying our sends, the link is
    /// gone — and redialled straight away when the peer is one we keep warm,
    /// since a dropped link to someone still online is a fault to repair,
    /// not a fact to report.
    private func lost(_ connection: Connection, to userID: UUID) {
        let (wasCurrent, redial) = lock.withLock {
            guard connections[userID] === connection else { return (false, false) }
            connections[userID] = nil
            outbound[userID] = nil
            return (true, warm.contains(userID))
        }
        guard wasCurrent else { return }
        onLink(userID, nil)
        print("peer: \(userID) link lost\(redial ? ", redialling" : "")")
        if redial {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.dial(userID)
            }
        }
    }

    // MARK: - Frames

    /// Writes a frame to one peer, dialling first if there's no link and
    /// waiting up to `linkTimeout` for one. Throws when it can't be
    /// delivered; what that means is the caller's to decide.
    func send(_ frame: PeerFrame, to userID: UUID) async throws {
        let data = try PeerWire.encode(frame)
        let connection = try await link(to: userID)
        let writer = lock.withLock {
            if let existing = outbound[userID], existing.connection === connection {
                return existing
            }
            let fresh = Outbound(connection)
            outbound[userID] = fresh
            return fresh
        }
        try await writer.write(data)
    }

    /// Write with no one waiting on the bytes reaching the buffer. Delivery is
    /// judged by the peer's ack, not by the write returning — a write into a
    /// full flow-control window (a peer that went silent) blocks for the
    /// connection's whole idle timeout, and nothing that matters should wait
    /// on it. The write still runs, bounded and self-healing, so it lands if
    /// the peer is merely slow.
    func sendBestEffort(_ frame: PeerFrame, to userID: UUID) {
        Task { [weak self] in try? await self?.send(frame, to: userID) }
    }

    private func link(to userID: UUID) async throws -> Connection {
        if let connection = lock.withLock({ connections[userID] }) { return connection }
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            let stopped = lock.withLock {
                guard endpoint != nil else { return true }
                waiting[userID, default: []].append(waiter)
                return false
            }
            if stopped {
                waiter.resume(throwing: LinkError.stopped)
                return
            }
            dial(userID)
            Task { [weak self] in
                try? await Task.sleep(for: Self.linkTimeout)
                self?.fail(userID, with: LinkError.noLink, only: waiter)
            }
        }
    }

    /// Fails frames waiting on a user's link — all of them, or just one
    /// whose own clock ran out.
    private func fail(_ userID: UUID, with error: Error, only waiter: Waiter? = nil) {
        let failed: [Waiter] = lock.withLock {
            guard let pending = waiting[userID] else { return [] }
            if let waiter {
                let remaining = pending.filter { $0 !== waiter }
                waiting[userID] = remaining.isEmpty ? nil : remaining
                return pending.count == remaining.count ? [] : [waiter]
            }
            waiting[userID] = nil
            return pending
        }
        for waiter in failed {
            waiter.resume(throwing: error)
        }
    }

    private func read(_ stream: RecvStream, from userID: UUID) async {
        var decoder = PeerWire.Decoder()
        while let chunk = try? await stream.read(sizeLimit: 16 * 1024), !chunk.isEmpty {
            guard let frames = try? decoder.append(chunk) else {
                try? await stream.stop(errorCode: 1)
                return
            }
            for frame in frames {
                onFrame(Inbound(senderID: userID, frame: frame))
            }
        }
    }

    /// A continuation that resumes at most once, whichever of the link, its
    /// failure, or the timeout gets there first.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Connection, Error>?

        init(_ continuation: CheckedContinuation<Connection, Error>) {
            self.continuation = continuation
        }

        func resume(returning connection: Connection) {
            lock.withLock { defer { continuation = nil }; return continuation }?
                .resume(returning: connection)
        }

        func resume(throwing error: Error) {
            lock.withLock { defer { continuation = nil }; return continuation }?
                .resume(throwing: error)
        }
    }

    /// One peer's outgoing frame stream. An actor so frames from different
    /// tasks can't interleave mid-write — length-prefixed framing survives
    /// nothing else. The stream is opened on first use and reopened after a
    /// failed write.
    private actor Outbound {
        nonisolated let connection: Connection
        private var stream: SendStream?

        init(_ connection: Connection) {
            self.connection = connection
        }

        func write(_ data: Data) async throws {
            let stream: SendStream
            if let open = self.stream {
                stream = open
            } else {
                stream = try await connection.openUni()
                self.stream = stream
            }
            do {
                try await withDeadline(PeerLink.writeTimeout) {
                    try await stream.writeAll(buf: data)
                } onExpiry: {
                    // Abort the stuck write so `writeAll` throws instead of
                    // waiting out the connection's idle timeout; a reset
                    // stream is spent, so the next frame opens a new one.
                    try? await stream.reset(errorCode: 0)
                }
            } catch {
                self.stream = nil
                throw error
            }
        }
    }

    /// Runs `work` but gives up after `deadline`, calling `onExpiry` to unwedge
    /// whatever it was blocked on so it actually returns. Without the unwedge a
    /// non-cancellable FFI call would keep the task group from ever unwinding.
    private static func withDeadline(
        _ deadline: Duration,
        _ work: @escaping @Sendable () async throws -> Void,
        onExpiry: @escaping @Sendable () async -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await work()
                } onCancel: {
                    Task { await onExpiry() }
                }
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw LinkError.writeStalled
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    // MARK: - Voice packets

    func send(_ packet: Data, in conversationID: UUID) {
        let targets: [Connection] = lock.withLock {
            sequence &+= 1
            return (recipients[conversationID] ?? []).compactMap { connections[$0] }
        }
        guard !targets.isEmpty else { return }
        var datagram = Data(capacity: Self.headerBytes + packet.count)
        withUnsafeBytes(of: conversationID.uuid) { datagram.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.littleEndian) { datagram.append(contentsOf: $0) }
        datagram.append(packet)
        for connection in targets {
            try? connection.sendDatagram(data: datagram)
        }
    }

    /// A packet that overtook a later one is dropped: playing it now would
    /// put 20 ms of the past after the present.
    private func receiveDatagram(_ datagram: Data, from userID: UUID) {
        guard datagram.count > Self.headerBytes else { return }
        let conversationID = datagram.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        let sequence = datagram.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
        }
        let inOrder = lock.withLock {
            if let last = lastSequence[userID], sequence <= last, last - sequence < 1_000 { return false }
            lastSequence[userID] = sequence
            return true
        }
        guard inOrder else { return }
        onAudio(AudioFrame(senderID: userID, conversationID: conversationID,
                           packet: datagram.suffix(from: Self.headerBytes)))
    }
}
