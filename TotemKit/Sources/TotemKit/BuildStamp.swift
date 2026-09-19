import Foundation

/// Compares the running build against the newest one testers can install.
public enum BuildStamp {
    /// Distributed builds are stamped `YYYYMMDDHHMM`, fixed-width and
    /// monotonic, so they compare as integers. Anything else is a local build
    /// and is never out of date.
    public static func isOutdated(_ current: String?, latestAvailable latest: String?) -> Bool {
        guard let current = stamp(current), let latest = stamp(latest) else { return false }
        return current < latest
    }

    private static func stamp(_ value: String?) -> Int? {
        guard let value, value.count == 12, value.allSatisfy(\.isNumber) else { return nil }
        return Int(value)
    }
}
