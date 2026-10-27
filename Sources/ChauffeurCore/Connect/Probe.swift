import Foundation

/// What the probes decided about a key before it is stored.
public enum ProbeVerdict: Equatable, Sendable {
    case refusedAdmin
    case refusedCertificates
    case accepted(apps: [String])
    case unauthorized
    case rateLimited(remaining: Int)
}

/// Three GET requests that tell an Admin key, a key that reaches Certificates, Identifiers & Profiles, and an
/// acceptable App Manager or Developer key apart. Each stops as soon as the answer is known.
public enum Probe {
    /// The verdict for the statuses seen so far, or nil when a status means an error the caller reports.
    public static func decide(users: Int, certificates: Int?, apps: [String]?) -> ProbeVerdict? {
        switch users {
        case 401: return .unauthorized
        case 429: return .rateLimited(remaining: 0)
        case 200: return .refusedAdmin
        case 403: break
        default: return nil
        }
        switch certificates {
        case 401: return .unauthorized
        case 429: return .rateLimited(remaining: 0)
        case 200: return .refusedCertificates
        case 403: return apps.map { .accepted(apps: $0) }
        default: return nil
        }
    }

    /// Runs the probes in order. Throws the `ConnectError` for a status the table has no verdict for.
    public static func run(_ client: ConnectClient) throws -> ProbeVerdict {
        let users = try client.perform(.probeUsers)
        guard users.status == 403 else {
            return try verdict(decide(users: users.status, certificates: nil, apps: nil), users, .probeUsers, client)
        }
        try client.ensure(requests: 2)
        let certificates = try client.perform(.probeCertificates)
        guard certificates.status == 403 else {
            let decided = decide(users: 403, certificates: certificates.status, apps: nil)
            return try verdict(decided, certificates, .probeCertificates, client)
        }
        let json: JSON
        do {
            json = try client.send(.probeApps)
        } catch ConnectError.unauthorized {
            return .unauthorized
        } catch ConnectError.rateLimited(let remaining) {
            return .rateLimited(remaining: remaining)
        }
        let visible = apps(from: json)
        return decide(users: 403, certificates: 403, apps: visible) ?? .accepted(apps: visible)
    }

    private static func verdict(
        _ decided: ProbeVerdict?, _ response: ConnectResponse, _ op: Operation, _ client: ConnectClient
    ) throws -> ProbeVerdict {
        switch decided {
        case .rateLimited?: return .rateLimited(remaining: client.rateLimit?.remaining ?? 0)
        case let decided?: return decided
        case nil:
            throw client.error(for: response, op: op)
                ?? ConnectError.apple(status: response.status, shape: "GET \(RequestTable.path(for: op))", errors: [])
        }
    }

    /// `name (bundleId)` for each app, escaped, sorted by name. At most the first 200 Apple returned.
    public static func apps(from json: JSON) -> [String] {
        let records = json["data"]?.array ?? []
        let names: [String] = records.compactMap { record in
            guard let name = record["attributes"]?["name"]?.string else { return nil }
            let shown = Perception.escape(name, limit: 40)
            guard let bundleID = record["attributes"]?["bundleId"]?.string else { return shown }
            return "\(shown) (\(Perception.escape(bundleID)))"
        }
        return names.sorted()
    }

    /// What to tell the human about a verdict.
    public static func message(_ v: ProbeVerdict) -> String {
        switch v {
        case .refusedAdmin:
            return
                "refused: Admin key. This key can remove every other Admin and change roles. chauffeur never holds one. In App Store Connect, create a key with the App Manager role and no access to Certificates, Identifiers & Profiles."
        case .refusedCertificates:
            return
                "refused: this key reaches Certificates, Identifiers & Profiles. It can revoke the team's distribution certificate, which breaks every profile and unsubmitted build. Create one without that access."
        case .unauthorized:
            return ConnectError.unauthorized.description
        case .rateLimited(let remaining):
            return ConnectError.rateLimited(remaining: remaining).description
        case .accepted(let apps):
            return "accepted: \(apps.count) apps visible"
        }
    }
}
