import Foundation

/// Comparing the build a client is running against the newest one testers can
/// install. Pure and clock-free, like the rest of the shared core.
public enum BuildStamp {
    /// `testflight.sh` stamps every distributed build `YYYYMMDDHHMM`, which is
    /// fixed-width and monotonic, so builds compare as plain integers.
    ///
    /// Anything not of that shape is a locally-built one — `project.yml`'s
    /// default is `"1"` — and is never out of date. Without that, every debug
    /// build off `install.sh` would claim an update was waiting, and the one
    /// place the banner must not cry wolf is the machine it's developed on.
    public static func isOutdated(_ current: String?, latestAvailable latest: String?) -> Bool {
        guard let current = stamp(current), let latest = stamp(latest) else { return false }
        return current < latest
    }

    private static func stamp(_ value: String?) -> Int? {
        guard let value, value.count == 12, value.allSatisfy(\.isNumber) else { return nil }
        return Int(value)
    }
}
