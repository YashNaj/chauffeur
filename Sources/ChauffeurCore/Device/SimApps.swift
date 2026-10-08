import Foundation

/// What chauffeur reads from `simctl` app commands and from a built `.app`.
public enum SimApps {
    public struct AppInfo: Equatable, Sendable {
        public var executable: String
        /// What the accessibility root label shows when the app is in front.
        public var displayName: String
    }

    /// `simctl appinfo` prints an OpenStep property list; nil when it is not one (app not installed).
    public static func appInfo(_ out: String) -> AppInfo? {
        guard let d = (try? PropertyListSerialization.propertyList(from: Data(out.utf8), options: [], format: nil)) as? [String: Any],
              let executable = d["CFBundleExecutable"] as? String else { return nil }
        let name = (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String) ?? executable
        return AppInfo(executable: executable, displayName: name)
    }

    /// `simctl launch` prints `dev.chauffeur.fixture: 4321`.
    public static func launchedPID(_ out: String) -> Int32? {
        guard let line = out.split(separator: "\n").last, let colon = line.lastIndex(of: ":") else { return nil }
        return Int32(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// SpringBoard's pid from `simctl spawn <udid> launchctl list`; nil when it is not running.
    public static func springBoardPID(_ launchctlList: String) -> Int32? {
        for line in launchctlList.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            if cols.count == 3, cols[2] == "com.apple.SpringBoard" { return Int32(cols[0]) }
        }
        return nil
    }

    public struct AppBundle: Equatable, Sendable {
        public var identifier: String
        /// `0.1 (1)`
        public var version: String
    }

    /// The bundle id and version of a built `.app`, from its Info.plist (XML or binary).
    public static func bundle(at app: URL) -> AppBundle? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let d = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let identifier = d["CFBundleIdentifier"] as? String else { return nil }
        let version = [d["CFBundleShortVersionString"] as? String, (d["CFBundleVersion"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        return AppBundle(identifier: identifier, version: version)
    }
}
