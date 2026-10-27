import Foundation

/// The four lines a human reads before a key is stored: who the key is, what it can, what it can't, and what
/// chauffeur will never do with it.
public enum CapabilitySheet {
    /// The size of the probe's apps page. A list this long may be cut, so the sheet says `and more`.
    static let appsLimit = 200

    /// `apps` are already escaped (`Probe.apps(from:)`). Never renders a token or the key itself.
    public static func render(keyID: String, role: ConnectRole, issuer: String, apps: [String]) -> String {
        var shownApps = apps.isEmpty ? "none visible" : apps.joined(separator: ", ")
        if apps.count >= appsLimit { shownApps += " and more" }
        let head = "key \(keyID) · \(role.title) · issuer \(issuer.prefix(8))… · apps: \(shownApps)"
        return [head, "can:    " + can(role), "cannot: " + cannot(role), "chauffeur will never: " + never()]
            .joined(separator: "\n")
    }

    private static func can(_ role: ConnectRole) -> String {
        switch role {
        case .appManager:
            return
                "upload builds · manage TestFlight groups and testers · edit version metadata · submit for review · release"
        case .developer:
            return "upload builds · read builds, TestFlight and version state"
        }
    }

    private static let neverAnyone =
        "touch certificates, identifiers or profiles · add or remove people · change roles · delete apps · create keys"

    private static func cannot(_ role: ConnectRole) -> String {
        switch role {
        case .appManager: return neverAnyone
        case .developer: return "submit for review · edit version metadata · manage testers · " + neverAnyone
        }
    }

    private static func never() -> String { RequestTable.never().joined(separator: " · ") }
}
