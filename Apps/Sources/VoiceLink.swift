import Foundation
import IrohLib

/// Live voice never crosses the server. Each signed-on device runs an iroh
/// endpoint and talks to its peers over QUIC datagrams, one Opus packet each;
/// the server only introduces people. Every ticket it relays arrives with the
/// user it belongs to, and that map is the whole access control: a connection
/// from an endpoint the server never named is refused.
///
/// Safe from any thread — the capture tap sends from the audio thread and the
/// model drives everything else from the main actor.
final class VoiceLink: @unchecked Sendable {
    struct Frame: Sendable {
        let senderID: UUID
        let conversationID: UUID
        let packet: Data
    }

    private static let alpn = Data("totem/voice/1".utf8)
    /// Conversation ID, then a per-sender sequence number, ahead of the packet.
    private static let headerBytes = 16 + 4
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
    private var dialing: Set<UUID> = []
    private var recipients: [UUID: Set<UUID>] = [:]
    private var sequence: UInt32 = 0
    private var lastSequence: [UUID: UInt32] = [:]
    private let onTicket: @Sendable (String) -> Void
    private let onFrame: @Sendable (Frame) -> Void

    init(onTicket: @escaping @Sendable (String) -> Void,
         onFrame: @escaping @Sendable (Frame) -> Void) {
        self.onTicket = onTicket
        self.onFrame = onFrame
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
            print("voice endpoint failed to start: \(error)")
        }
    }

    func stop() async {
        acceptLoop?.cancel()
        acceptLoop = nil
        addrPoll?.cancel()
        addrPoll = nil
        let (endpoint, open) = lock.withLock {
            defer {
                self.endpoint = nil
                ticket = nil
                addresses = [:]
                users = [:]
                connections = [:]
                recipients = [:]
                lastSequence = [:]
            }
            return (self.endpoint, Array(connections.values))
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
    /// they're in a conversation we're already sending to.
    func setPeer(_ userID: UUID, ticket: String) {
        guard let addr = try? EndpointTicket.fromString(str: ticket).endpointAddr() else { return }
        let wanted = lock.withLock {
            addresses[userID] = addr
            users[addr.id().description] = userID
            return recipients.values.contains { $0.contains(userID) }
        }
        if wanted { dial(userID) }
    }

    func removePeer(_ userID: UUID) {
        let connection = lock.withLock {
            if let addr = addresses.removeValue(forKey: userID) {
                users[addr.id().description] = nil
            }
            lastSequence[userID] = nil
            return connections.removeValue(forKey: userID)
        }
        try? connection?.close(errorCode: 0, reason: Data())
    }

    /// Who a conversation's packets go to. Dials everyone not yet connected
    /// so the first packet doesn't wait on a handshake.
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
        Task {
            defer { lock.withLock { _ = dialing.remove(userID) } }
            guard let connection = try? await endpoint.connect(addr: addr, alpn: Self.alpn)
            else { return }
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
        lock.withLock { connections[userID] = connection }
        Task { [weak self] in
            // Whether the link punched through or is riding a relay is the
            // one fact worth having when someone reports choppy voice.
            try? await Task.sleep(for: .seconds(3))
            let paths = connection.paths().filter(\.isSelected)
                .map { "\($0.isIp ? "direct" : "relay") \($0.remoteAddr)" }
            print("voice: \(userID) via \(paths.joined(separator: ", "))")
        }
        Task { [weak self] in
            while let datagram = try? await connection.readDatagram() {
                self?.receive(datagram, from: userID)
            }
            self?.lock.withLock {
                guard let self, self.connections[userID] === connection else { return }
                self.connections[userID] = nil
            }
        }
    }

    // MARK: - Packets

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
    private func receive(_ datagram: Data, from userID: UUID) {
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
        onFrame(Frame(senderID: userID, conversationID: conversationID,
                      packet: datagram.suffix(from: Self.headerBytes)))
    }
}
