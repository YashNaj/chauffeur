import Foundation

/// Which simulator a command targets (spec §5.1).
public enum Target {
    public static let configName = ".chauffeur.json"

    public static func resolve(flag: String?, env: String?, configUDID: String?, devices: [DeviceInfo]) throws -> String {
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

    /// Looks for `.chauffeur.json` in `dir` and its ancestors.
    public static func readConfig(from dir: URL) -> String? {
        var current = dir.standardizedFileURL
        while true {
            let file = current.appendingPathComponent(configName)
            if let data = try? Data(contentsOf: file),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let udid = object["udid"] as? String {
                return udid
            }
            // Directory URLs walk "/" → "/.." → "/../..", so stop at the root explicitly.
            if current.path == "/" { return nil }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    public static func writeConfig(udid: String, in dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["udid": udid], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(configName))
    }
}
