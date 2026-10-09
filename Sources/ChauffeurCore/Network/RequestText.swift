import Foundation

/// How a request reads in a result (M4b spec §3, owner decision 2026-10-08): what happened in words, the numbers
/// behind it, and what to try. Hosts and paths come from the network: escaped like log text.
public enum RequestText {
    /// `localhost:8765/fail`, `api.example.com/login`: the port only when it isn't the scheme's usual one, and always
    /// for a bare IP.
    public static func target(_ i: RequestItem) -> String {
        hostPort(i) + Perception.escape(i.path ?? "", limit: 120)
    }

    static func hostPort(_ i: RequestItem) -> String {
        guard !i.host.isEmpty else { return "a request" }
        let host = Perception.escape(i.host.contains(":") ? "[\(i.host)]" : i.host, limit: 80)
        guard let port = i.port, !(i.hostKnown && (port == 80 || port == 443)) else { return host }
        return "\(host):\(port)"
    }

    /// What happened, for a headline.
    public static func outcome(_ i: RequestItem, elapsedMs: Int) -> String {
        let t = target(i)
        if i.streaming { return t + " · connected, data flowing" }
        if i.waiting {
            return i.hostKnown
                ? t + " still running after " + duration(elapsedMs)
                : t + " · sent " + bytes(i.sent ?? 0) + ", no reply after " + duration(elapsedMs)
        }
        if let code = i.errorCode {
            return t + " failed: \(errorName(code)) (\(code))" + (i.ms.map { " after " + duration($0) } ?? "")
        }
        if let status = i.status {
            return t + " → \(status)" + (statusName(status).map { " " + $0 } ?? "")
                + (i.ms.map { " in " + duration($0) } ?? "") + (i.serverMs.map { " (server \(duration($0)))" } ?? "")
        }
        return t + " · sent \(bytes(i.sent ?? 0)), got \(bytes(i.received ?? 0))"
    }

    /// The numbers behind it: `sent 300 B (body 14 B), got 104 B · http/1.1`; empty when there are none.
    public static func details(_ i: RequestItem) -> String {
        var parts: [String] = []
        if i.hostKnown, i.status != nil || i.errorCode != nil, let sent = i.sent, let received = i.received,
            sent + received > 0
        {
            let body = i.bodyBytes.flatMap { $0 > 0 ? " (body \(bytes($0)))" : nil } ?? ""
            parts.append("sent \(bytes(sent))\(body), got \(bytes(received))")
        }
        if i.streaming, let received = i.received { parts.append("got \(bytes(received))") }
        if i.hostKnown, let proto = i.proto { parts.append(Perception.escape(proto, limit: 20)) }
        if !i.hostKnown, !i.host.isEmpty {
            parts.append("telemetry filter unavailable for " + Perception.escape(i.host, limit: 80))
        }
        return parts.joined(separator: " · ")
    }

    public static func line(_ i: RequestItem, elapsedMs: Int) -> String {
        let more = details(i)
        return "request: " + outcome(i, elapsedMs: elapsedMs) + (more.isEmpty ? "" : " · " + more)
    }

    /// A line per request but `except` (the one a headline already names), then the telemetry line.
    public static func lines(_ items: [RequestItem], elapsedMs: Int, except lead: RequestItem? = nil) -> [String] {
        var rest = items.filter { !$0.telemetry }
        if let lead, let i = rest.firstIndex(of: lead) { rest.remove(at: i) }
        return rest.map { line($0, elapsedMs: elapsedMs) } + (telemetry(items).map { [$0] } ?? [])
    }

    /// `telemetry: 2 requests (app-measurement.com, sentry.io)`; never in a headline (spec §3).
    public static func telemetry(_ items: [RequestItem]) -> String? {
        let pings = items.filter(\.telemetry)
        guard !pings.isEmpty else { return nil }
        var hosts: [String] = []
        for p in pings where !hosts.contains(p.host) { hosts.append(p.host) }
        return "telemetry: \(pings.count) request\(pings.count == 1 ? "" : "s") ("
            + hosts.map { Perception.escape($0, limit: 80) }.joined(separator: ", ") + ")"
    }

    /// What to try, for a failure or a success that changed nothing.
    public static func hint(_ i: RequestItem) -> String? {
        if let code = i.errorCode {
            switch code {
            case -1004: return "nothing accepted the connection at \(hostPort(i)); is the server running?"
            case -1001: return "the server didn't answer in time"
            case -1003: return "\(hostPort(i)) doesn't resolve; check the URL and the simulator's network"
            case -1009: return "the simulator is offline"
            case -1005: return "the connection dropped mid-request; retry, or check the server"
            case -1206 ... -1200: return "the secure connection failed: a certificate or App Transport Security problem"
            default: return nil
            }
        }
        guard let status = i.status else { return nil }
        switch status {
        case 401, 403: return "the server refused the request (\(status)); the app may be signed out"
        case 404: return "the server has nothing at that path (404); the app may call the wrong URL"
        case 429: return "the server is rate-limiting the app (429)"
        case 500...599:
            return "the server failed (\(status)) and the app shows nothing for it; check the server or the app's "
                + "error handling"
        case 200...299:
            return "the request succeeded but the screen didn't change; the app may not update the screen for this "
                + "response"
        default: return nil
        }
    }

    /// The JSON `requests` entry (spec §3): fields absent when the layer that provides them saw nothing.
    public static func json(_ i: RequestItem) -> JSON {
        var o: [String: JSON] = [
            "host": .string(i.host), "waiting": .bool(i.waiting), "streaming": .bool(i.streaming),
            "telemetry": .bool(i.telemetry),
        ]
        if let v = i.port { o["port"] = JSON(v) }
        if let v = i.path { o["path"] = .string(v) }
        if let v = i.status { o["status"] = JSON(v) }
        if let v = i.errorCode { o["error"] = JSON(v) }
        if let v = i.ms { o["ms"] = JSON(v) }
        if let v = i.serverMs { o["serverMs"] = JSON(v) }
        if let v = i.sent { o["sent"] = JSON(v) }
        if let v = i.received { o["received"] = JSON(v) }
        if let v = i.proto { o["protocol"] = .string(v) }
        if let v = i.bodyBytes { o["body"] = JSON(v) }
        return .object(o)
    }

    static func statusName(_ code: Int) -> String? {
        [
            200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 301: "Moved Permanently", 302: "Found",
            304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
            409: "Conflict", 422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error",
            502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
        ][code]
    }

    static func errorName(_ code: Int) -> String {
        [
            -999: "cancelled", -1001: "timed out", -1003: "host not found", -1004: "could not connect to the server",
            -1005: "connection lost", -1009: "offline", -1011: "bad server response",
            -1200: "secure connection failed", -1202: "untrusted certificate",
        ][code] ?? "network error"
    }

    static func bytes(_ n: Int) -> String {
        if n < 1000 { return "\(n) B" }
        if n < 1_000_000 { return String(format: "%.1f KB", Double(n) / 1000) }
        return String(format: "%.1f MB", Double(n) / 1_000_000)
    }

    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }
}
