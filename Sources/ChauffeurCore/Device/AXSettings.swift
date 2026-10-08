import Foundation

/// The simulator's app-accessibility switches. backboardd turns them off when the last accessibility observer leaves
/// (XCTest at the end of an Xcode device-interaction session), and an app launched while they are off never starts its
/// accessibility server: it has no tree until it is relaunched.
public enum AXSettings {
    public static let domain = "com.apple.Accessibility"
    public static let flags = ["ApplicationAccessibilityEnabled", "AutomationEnabled"]

    /// The flags `defaults read com.apple.Accessibility` shows as off or missing.
    public static func off(_ defaultsRead: String) -> [String] {
        let d =
            (try? PropertyListSerialization.propertyList(from: Data(defaultsRead.utf8), options: [], format: nil))
            as? [String: Any]
        return flags.filter { key in
            guard let value = d?[key] else { return true }
            return "\(value)" != "1"
        }
    }

    /// Turns on the flags that are off and returns them (empty when all were on).
    public static func ensure(udid: String) throws -> [String] {
        let read = try SimCtl.run(["spawn", udid, "defaults", "read", domain])
        let missing = off(read.out)
        for key in missing {
            try SimCtl.run(["spawn", udid, "defaults", "write", domain, key, "-bool", "true"])
        }
        return missing
    }
}
