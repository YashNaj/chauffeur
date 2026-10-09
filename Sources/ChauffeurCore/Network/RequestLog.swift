import Foundation

/// One URLSession task, as Apple's networking log lines tell it (M4b spec §2, Findings §4).
public struct RequestRecord: Equatable, Sendable {
    /// `<task UUID>.<n>`, as CFNetwork names it.
    public var task: String
    public var scheme: String? = nil
    public var host: String? = nil
    public var port: Int? = nil
    /// The path's shape; nil when the task reused a connection another request set up (never guessed).
    public var path: String? = nil
    public var status: Int? = nil
    /// An `NSURLError` code such as -1004.
    public var errorCode: Int? = nil
    public var finished = false
    public var ms: Int? = nil
    /// How long the server took to start answering once the request was sent.
    public var serverMs: Int? = nil
    public var sent: Int? = nil
    public var received: Int? = nil
    public var proto: String? = nil
    /// From `sent request, body <kind> <bytes>` (`body N 0` without one, `body S 14` for 14 bytes).
    public var bodyBytes: Int? = nil
}

public enum RequestLog {
    /// The tasks that start in `lines` (a `resuming` line), in order. Lines of a task that started before them belong
    /// to an earlier action and are ignored.
    public static func parse(_ lines: [LogLine]) -> [RequestRecord] {
        var connections: [Int: Endpoint] = [:]
        var order: [String] = []
        var records: [String: RequestRecord] = [:]
        for line in lines {
            if line.sender == "Network", let (n, endpoint) = connectionURL(line.message) {
                connections[n] = endpoint
                continue
            }
            guard line.sender == "CFNetwork", let (task, event) = taskEvent(line.message) else { continue }
            if event.hasPrefix("resuming") {
                if records[task] == nil {
                    order.append(task)
                    records[task] = RequestRecord(task: task)
                }
                continue
            }
            guard var record = records[task] else { continue }
            apply(event, to: &record, connections: connections)
            records[task] = record
        }
        return order.compactMap { records[$0] }
    }

    struct Endpoint {
        var scheme: String
        var host: String
        var port: Int?
        var path: String
    }

    /// `[C7 <uuid> Hostname#…:8765 tcp, url: http://localhost:8765/fast, definite, …]` → (7, its endpoint). Lines of
    /// sub-connections (`[C7.1.1 …`) don't match.
    static func connectionURL(_ m: String) -> (Int, Endpoint)? {
        guard
            let match = m.prefixMatch(
                of: #/\[C(\d+) [^\]]*?url: ([A-Za-z][A-Za-z0-9+.\-]*):\/\/([^\/,\s]+)([^,\s]*)/#),
            let n = Int(match.output.1)
        else { return nil }
        let scheme = match.output.2.lowercased()
        let (host, port) = hostPort(String(match.output.3))
        let path = match.output.4.isEmpty ? "/" : String(match.output.4)
        return (n, Endpoint(scheme: scheme, host: host, port: port ?? defaultPort(scheme), path: path))
    }

    /// `Task <UUID>.<n> <event>` → ("UUID.n", event). The event may span lines (an error's user info).
    static func taskEvent(_ m: String) -> (String, String)? {
        guard let match = m.prefixMatch(of: #/Task <([0-9A-Fa-f\-]+)>\.<(\d+)> /#) else { return nil }
        return ("\(match.output.1).\(match.output.2)", String(m[match.range.upperBound...]))
    }

    static func apply(_ event: String, to r: inout RequestRecord, connections: [Int: Endpoint]) {
        if let m = event.prefixMatch(of: #/setting up Connection (\d+)/#),
            let e = Int(m.output.1).flatMap({ connections[$0] })
        {
            (r.scheme, r.host, r.port, r.path) = (e.scheme, e.host, e.port, e.path)
        } else if let m = event.prefixMatch(of: #/now using Connection (\d+)/#), r.host == nil,
            let e = Int(m.output.1).flatMap({ connections[$0] })
        {
            (r.scheme, r.host, r.port) = (e.scheme, e.host, e.port)  // a reused connection: its path is someone else's
        } else if let m = event.prefixMatch(of: #/sent request, body \S+ (\d+)/#) {
            r.bodyBytes = Int(m.output.1)
        } else if let m = event.prefixMatch(of: #/received response, status (\d+)/#) {
            r.status = Int(m.output.1)
        } else if let m = event.prefixMatch(of: #/HTTP load failed, .*?error code: (-?\d+)/#) {
            r.errorCode = Int(m.output.1)
        } else if let m = event.prefixMatch(of: #/finished with error \[(-?\d+)\]/#) {
            r.errorCode = Int(m.output.1)
            r.finished = true
        } else if event.hasPrefix("finished successfully") {
            r.finished = true
        } else if let m = event.prefixMatch(of: #/summary for task \w+ \{([^}]*)\}/#) {
            summary(String(m.output.1), into: &r)
        }
    }

    /// `transaction_duration_ms=481, response_status=500, …` from the task's summary line.
    static func summary(_ body: String, into r: inout RequestRecord) {
        var fields: [String: String] = [:]
        for pair in body.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            fields[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(
                in: CharacterSet(charactersIn: " \""))
        }
        func int(_ key: String) -> Int? { fields[key].flatMap { Int($0) } }
        r.ms = int("transaction_duration_ms") ?? r.ms
        if r.status == nil, let status = int("response_status"), status > 0 { r.status = status }
        r.sent = int("request_bytes") ?? r.sent
        r.received = int("response_bytes") ?? r.received
        r.proto = fields["protocol"] ?? r.proto
        if let answered = int("response_start_ms"), answered > 0, let asked = int("request_start_ms") {
            r.serverMs = max(0, answered - asked - (int("request_duration_ms") ?? 0))
        }
    }

    /// `localhost:8765` → ("localhost", 8765); `[::1]:8765` → ("::1", 8765); no port → nil.
    static func hostPort(_ authority: String) -> (String, Int?) {
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        let parts = authority.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (authority, nil)
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }
}
