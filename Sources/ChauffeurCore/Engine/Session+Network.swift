import Foundation

extension Session {
    /// What `network.telemetry` calls: the override, else `.chauffeur.json` from the client's directory.
    func telemetryHosts() -> [String] { telemetryOverride ?? Target.telemetryHosts(from: resolvePath(".")) }
}
