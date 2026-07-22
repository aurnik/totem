import Foundation

/// Exponential backoff for socket reconnects: 1s doubling to a 30s cap (spec §4).
/// `reset()` on successful connect, or when NWPathMonitor reports the network
/// returned, so the next attempt is immediate-ish.
public struct ReconnectPolicy: Equatable, Sendable {
    public static let initialDelay: TimeInterval = 1
    public static let maxDelay: TimeInterval = 30

    private var nextValue: TimeInterval = ReconnectPolicy.initialDelay

    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        let delay = nextValue
        nextValue = min(nextValue * 2, Self.maxDelay)
        return delay
    }

    public mutating func reset() {
        nextValue = Self.initialDelay
    }
}
