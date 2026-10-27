import Foundation

/// What the finance alarm could say about a key the probes accepted. It is never "proven App Manager".
public enum RoleCheck: Equatable, Sendable {
    /// `403 FORBIDDEN_ERROR` on finance reports: not an Admin, Account Holder or Finance key, as Apple answers today.
    case notFinanceCapable
    /// Any other answer, which proves nothing. A transport error is `(0, "transport")`.
    case unavailable(status: Int, code: String?)
}

/// What the probes decided about a key before it is stored.
public enum ProbeVerdict: Equatable, Sendable {
    case unauthorized
    case rateLimited(remaining: Int)
    case refusedFinance
    case accepted(apps: [String], roleCheck: RoleCheck)
}

/// Two GET requests: the apps the key sees, then the finance alarm. `GET /v1/financeReports` with a vendor number
/// that can't exist returns no data to anyone; Apple checks the role first, so a 400 means the key may read the
/// team's finance reports, which only Admin, Account Holder and Finance keys may. The alarm is one-way.
public enum Probe {
    /// The verdict for the answers seen so far, or nil when the caller must probe finance (`apps` 200 and
    /// `finance` nil) or report an error (any other `apps` status). A filled-in `accepted` has no apps yet.
    public static func decide(apps: Int, finance: (status: Int, code: String?)?) -> ProbeVerdict? {
        switch apps {
        case 401: return .unauthorized
        case 429: return .rateLimited(remaining: 0)
        case 200: break
        default: return nil
        }
        guard let finance else { return nil }
        switch (finance.status, finance.code) {
        case (400, "PARAMETER_ERROR.INVALID"): return .refusedFinance
        case (403, "FORBIDDEN_ERROR"): return .accepted(apps: [], roleCheck: .notFinanceCapable)
        default: return .accepted(apps: [], roleCheck: .unavailable(status: finance.status, code: finance.code))
        }
    }

    /// Runs the probes in order. Throws the `ConnectError` for an apps status the table has no verdict for, and
    /// `rateLimited` when no request is left for the alarm. Every answer from the alarm is a verdict.
    public static func run(_ client: ConnectClient, now: Date) throws -> ProbeVerdict {
        let response = try client.perform(.probeApps)
        guard response.status == 200 else {
            switch decide(apps: response.status, finance: nil) {
            case .rateLimited?: return .rateLimited(remaining: client.rateLimit?.remaining ?? 0)
            case let decided?: return decided
            case nil:
                throw client.error(for: response, op: .probeApps)
                    ?? ConnectError.apple(status: response.status, shape: "GET /v1/apps", errors: [])
            }
        }
        let json: JSON
        do {
            json = try JSON.parse(response.body)
        } catch {
            throw ConnectError.unexpectedBody(shape: "GET /v1/apps")
        }
        let visible = apps(from: json)
        try client.ensure(requests: 1)
        let finance: (status: Int, code: String?)
        do {
            let alarm = try client.perform(.probeFinance(month: lastMonth(now)))
            finance = (alarm.status, AppleError.parse(alarm.body).first?.code)
        } catch {
            finance = (0, "transport")
        }
        switch decide(apps: 200, finance: finance) {
        case .accepted(_, let roleCheck)?: return .accepted(apps: visible, roleCheck: roleCheck)
        case let decided?: return decided
        case nil: return .accepted(apps: visible, roleCheck: .unavailable(status: finance.status, code: finance.code))
        }
    }

    /// `yyyy-MM` of the month before `now`, in UTC.
    public static func lastMonth(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let date = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
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
        case .refusedFinance:
            return
                "refused: finance-capable key. This key can read the team's finance reports, which only Admin, Account Holder and Finance keys can. An Admin key can remove every other Admin, revoke certificates and delete identifiers; chauffeur never holds one. In App Store Connect, generate a key with the App Manager role."
        case .unauthorized:
            return ConnectError.unauthorized.description
        case .rateLimited(let remaining):
            return ConnectError.rateLimited(remaining: remaining).description
        case .accepted(let apps, _):
            return "accepted: \(apps.count) apps visible"
        }
    }
}
