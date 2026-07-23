// Client-only: the Linux (containerized server) build has no
// URLSessionWebSocketTask and never opens client sockets.
#if canImport(Darwin)
import Foundation

/// Live channel to the presence gateway over URLSessionWebSocketTask (spec §4).
/// Emits decoded server frames and connection lifecycle events; owns the 30s
/// heartbeat and reconnect backoff. Presence decisions stay in the state machine.
public actor SocketClient {

    public enum ConnectionEvent: Sendable {
        case connected
        case disconnected(Error?)
        case frame(ServerFrame)
    }

    public static let heartbeatInterval: TimeInterval = 30

    private let url: URL
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var policy = ReconnectPolicy()
    private var continuation: AsyncStream<ConnectionEvent>.Continuation?
    private var deliberatelyClosed = false

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    /// Connect and stream events until `close()` is called. Reconnects
    /// automatically with exponential backoff on non-deliberate drops.
    public func events() -> AsyncStream<ConnectionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            Task { await self.connect() }
        }
    }

    public func send(_ frame: ClientFrame) async throws {
        let data = try WireCoder.encoder().encode(frame)
        try await task?.send(.data(data))
    }

    /// Deliberate sign-off: sends the frame, closes the socket, no reconnect.
    public func close() async {
        deliberatelyClosed = true
        try? await send(.signOff)
        tearDown(code: .normalClosure)
        continuation?.finish()
    }

    /// Call when NWPathMonitor reports the network returned: resets backoff
    /// and retries immediately (spec §4).
    public func networkPathRestored() {
        policy.reset()
        if task == nil { Task { await connect() } }
    }

    private func connect() async {
        guard !deliberatelyClosed else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()

        // The handshake has no explicit callback here; the first successful
        // receive confirms the connection.
        receiveTask = Task { await self.receiveLoop(task) }
        heartbeatTask = Task { await self.heartbeatLoop() }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        var confirmed = false
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                if !confirmed {
                    confirmed = true
                    policy.reset()
                    continuation?.yield(.connected)
                }
                if let frame = decode(message) {
                    continuation?.yield(.frame(frame))
                }
            } catch {
                handleDrop(error)
                return
            }
        }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
            guard !Task.isCancelled else { return }
            try? await send(.heartbeat)
        }
    }

    private func handleDrop(_ error: Error) {
        tearDown(code: .abnormalClosure)
        guard !deliberatelyClosed else { return }
        continuation?.yield(.disconnected(error))
        let delay = policy.nextDelay()
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await self.connect()
        }
    }

    private func tearDown(code: URLSessionWebSocketTask.CloseCode) {
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        task?.cancel(with: code, reason: nil)
        task = nil
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) -> ServerFrame? {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return nil
        }
        return try? WireCoder.decoder().decode(ServerFrame.self, from: data)
    }
}
#endif
