import Foundation

/// Which simulator a command targets (spec §5.1).
public enum Target {
    public static let configName = ".chauffeur.json"

    public static func resolve(flag: String?, env: String?, configUDID: String?, devices: [DeviceInfo]) throws -> String
    {
        if let pinned = flag ?? env ?? configUDID { return try match(pinned, in: devices).udid }
        let booted = devices.filter(\.booted)
        switch booted.count {
        case 1: return booted[0].udid
        case 0: throw ChauffeurError.noBootedSimulator
        default: throw ChauffeurError.severalBooted(booted.map(\.summary))
        }
    }

    public static func match(_ nameOrUDID: String, in devices: [DeviceInfo]) throws -> DeviceInfo {
        if let d = devices.first(where: { $0.udid.caseInsensitiveCompare(nameOrUDID) == .orderedSame }) { return d }
        let named = devices.filter { $0.name == nameOrUDID }
        if named.count == 1 { return named[0] }
        let booted = named.filter(\.booted)
        if booted.count == 1 { return booted[0] }
        if named.isEmpty { throw ChauffeurError.unknownTarget(nameOrUDID, known: devices.map(\.summary)) }
        throw ChauffeurError.ambiguousTarget(nameOrUDID, matches: named.map(\.summary))
    }

    /// Looks for `.chauffeur.json` in `dir` and its ancestors: the nearest one that sets `udid`.
    public static func readConfig(from dir: URL) -> String? {
        nearest(from: dir) { $0["udid"] as? String }
    }

    /// The project's own telemetry entries (M4b spec §4): the nearest `.chauffeur.json` that sets `telemetryHosts`.
    public static func telemetryHosts(from dir: URL) -> [String] {
        nearest(from: dir) { $0["telemetryHosts"] as? [String] } ?? []
    }

    static func nearest<T>(from dir: URL, _ pick: ([String: Any]) -> T?) -> T? {
        var current = dir.standardizedFileURL
        while true {
            if let object = config(in: current), let value = pick(object) { return value }
            // Directory URLs walk "/" → "/.." → "/../..", so stop at the root explicitly.
            if current.path == "/" { return nil }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    static func config(in dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(configName)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Sets `udid` in `dir`'s `.chauffeur.json`, keeping every other key (`chauffeur use`).
    public static func writeConfig(udid: String, in dir: URL) throws {
        var object = config(in: dir) ?? [:]
        object["udid"] = udid
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(configName))
    }
}
