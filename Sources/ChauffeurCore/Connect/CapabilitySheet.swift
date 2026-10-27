import Foundation

/// The six lines a human reads before a key is stored: who the key is, what the finance alarm said, what the
/// declared role can and can't do, what nobody could verify, and what chauffeur will never do with it.
public enum CapabilitySheet {
    /// The size of the probe's apps page. A list this long may be cut, so the sheet says `and more`.
    static let appsLimit = 200

    /// `apps` are already escaped (`Probe.apps(from:)`). Never renders a token or the key itself.
    public static func render(
        keyID: String, role: ConnectRole, issuer: String, apps: [String], roleCheck: RoleCheck
    ) -> String {
        var shownApps = apps.isEmpty ? "none visible" : apps.joined(separator: ", ")
        if apps.count >= appsLimit { shownApps += " and more" }
        let head = "key \(keyID) · \(role.title) (declared) · issuer \(issuer.prefix(8))… · apps: \(shownApps)"
        return [
            head, "role check: " + check(roleCheck, role), "can:    " + can(role), cannot(role),
            "unverified for this role: revoking certificates, deleting profiles and identifiers · "
                + "chauffeur has no such request",
            "chauffeur will never: " + never(),
        ].joined(separator: "\n")
    }

    private static func check(_ roleCheck: RoleCheck, _ role: ConnectRole) -> String {
        switch roleCheck {
        case .notFinanceCapable:
            return "not an Admin or Finance key (finance alarm) · App Store Connect offers no other read-back"
        case .unavailable(let status, let code):
            // Apple's code is untrusted text.
            let parts = [status == 0 ? nil : "\(status)", code.map { Perception.escape($0) }].compactMap { $0 }
            return "unavailable (\(parts.joined(separator: " "))) · taking \(role.title) as declared"
        }
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

    /// What Apple's role chart withholds from App Manager and Developer alike.
    private static let chart = "add or remove Admins · generate keys · remove or transfer apps · sign agreements"

    private static func cannot(_ role: ConnectRole) -> String {
        switch role {
        case .appManager: return "cannot (Apple's role chart): " + chart
        case .developer: return "cannot: submit for review · edit version metadata · manage testers · " + chart
        }
    }

    private static func never() -> String { RequestTable.never().joined(separator: " · ") }
}
