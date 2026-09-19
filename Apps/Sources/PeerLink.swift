import Foundation
import IrohLib
import TotemKit

/// Peer-to-peer transport for conversation traffic, which never reaches the
/// server: one iroh QUIC connection per peer, carrying voice as datagrams and
/// ordered traffic as length-prefixed `PeerFrame`s on a stream. The server's
/// user-to-endpoint map is the access control, so connections from endpoints
/// it never named are refused and inbound frames are stamped with the user
/// their connection was accepted for.
///
/// Each side opens its own unidirectional stream because a QUIC stream does
/// not exist at the far end until bytes flow on it, so on a shared
/// bidirectional stream the accepting side could never speak first.
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

    /// A link opens on the relay and moves to a direct path once hole punching lands.
    enum LinkState: Sendable {
        case connecting, relay, direct
    }

    enum LinkError: Error {
        /// No link came up in time, or the server never introduced the peer.
        case noLink
        case stopped
        /// The write did not drain inside `writeTimeout` and was aborted.
        case writeStalled
    }

    /// A stalled write is aborted after this rather than blocking for the connection's idle timeout.
    static let writeTimeout: Duration = .seconds(4)

    private static let alpn = Data("totem/peer/1".utf8)
    /// Conversation ID, then a per-sender sequence number, ahead of the packet.
    private static let headerBytes = 16 + 4
    /// How long a frame waits for a link to come up before it fails.
    static let linkTimeout: Duration = .seconds(5)
    private static let keyURL = URL.applicationSupportDirectory
        .appendingPathComponent("voice.key")

    private let lock = NSLock()
    private var endpoint: Endpoint?
    private var acceptLoop: Task<Void, Never>?
    private var addrPoll: Task<Void, Never>?
    private(set) var ticket: String?
    /// Where each introduced user is dialed. Doubles as the accept side's allow-list.
    private var addresses: [UUID: EndpointAddr] = [:]
    private var users: [String: UUID] = [:]
    private var connections: [UUID: Connection] = [:]
    private var outbound: [UUID: Outbound] = [:]
    private var dialing: Set<UUID> = []
    private var waiting: [UUID: [Waiter]] = [:]
    /// Peers whose link is kept up, redialed whenever it drops.
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

    /// Binds under this device's persistent identity. `online()` is what
    /// registers with a relay; without it nobody off the LAN can dial.
    func start() async {
        do {
            let endpoint = try await Endpoint.bind(options: EndpointOptions(
                preset: presetN0(), secretKey: Self.secretKey().toBytes(), alpns: [Self.alpn]))
            lock.withLock { self.endpoint = endpoint }
            await endpoint.online()
            publishTicket(for: endpoint.addr())
            // The FFI's address watcher is unusable from Swift, so poll instead;
            // a network change is re-announced within this interval.
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
            Log.peer.error("endpoint failed to start: \(error)")
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

    /// The server introduced (or re-introduced) a user, dialed if already wanted.
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

    /// The peers whose links stay up. Absolute: the caller passes the whole set.
    func keepWarm(_ userIDs: Set<UUID>) {
        lock.withLock { warm = userIDs }
        for userID in userIDs { dial(userID) }
    }

    /// Who a conversation's voice packets go to. Dials anyone not yet connected.
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

    /// Both sides may dial at once; the newest connection carries our sends.
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
        Task { [weak self] in
            var last: LinkState?
            while !reading.isCancelled, let self, self.lock.withLock({ self.connections[userID] === connection }) {
                let selected = connection.paths().first { $0.isSelected }
                let state: LinkState = selected.map { $0.isIp ? .direct : .relay } ?? .connecting
                if state != last {
                    last = state
                    self.onLink(userID, state)
                    Log.peer.info("\(userID) \(String(describing: state)) \(selected?.remoteAddr ?? "")")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// A lost connection is redialed when the peer is one we keep warm.
    private func lost(_ connection: Connection, to userID: UUID) {
        let (wasCurrent, redial) = lock.withLock {
            guard connections[userID] === connection else { return (false, false) }
            connections[userID] = nil
            outbound[userID] = nil
            return (true, warm.contains(userID))
        }
        guard wasCurrent else { return }
        onLink(userID, nil)
        Log.peer.info("\(userID) link lost\(redial ? ", redialling" : "")")
        if redial {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.dial(userID)
            }
        }
    }

    // MARK: - Frames

    /// Writes a frame to one peer, dialing first and waiting up to `linkTimeout`.
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

    /// Fire-and-forget write. Delivery is judged by the peer's ack, not by the
    /// write returning, which can block for a long time against a silent peer.
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

    /// Fails all frames waiting on a user's link, or just one whose clock ran out.
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

    /// A continuation that resumes at most once: link, failure, or timeout.
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

    /// One peer's outgoing frame stream. An actor so writes from different tasks
    /// cannot interleave and corrupt the length-prefixed framing.
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
                    // A reset stream is spent, so the next frame opens a new one.
                    try? await stream.reset(errorCode: 0)
                }
            } catch {
                self.stream = nil
                throw error
            }
        }
    }

    /// Runs `work` with a deadline, calling `onExpiry` to unwedge it. Without
    /// that, a non-cancellable FFI call would keep the task group from unwinding.
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

    /// Out-of-order packets are dropped rather than played behind the present.
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
