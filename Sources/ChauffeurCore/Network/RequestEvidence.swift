import Foundation

/// One request or connection a tap caused, as the agent sees it (M4b spec §3, §6).
public struct RequestItem: Equatable, Sendable {
    /// A host name from the logs, or the remote IP when only the activity layer saw it; empty while a task has no
    /// connection yet.
    public var host: String
    public var port: Int? = nil
    /// The path's shape; nil when unknown (activity only, or a reused connection).
    public var path: String? = nil
    public var status: Int? = nil
    public var errorCode: Int? = nil
    public var ms: Int? = nil
    public var serverMs: Int? = nil
    public var sent: Int? = nil
    public var received: Int? = nil
    public var proto: String? = nil
    public var bodyBytes: Int? = nil
    public var waiting = false
    public var streaming = false
    public var telemetry = false
    /// False when only the activity layer saw it: its host is an IP, so the telemetry filter couldn't run.
    public var hostKnown = true

    public var failed: Bool { errorCode != nil || (status ?? 0) >= 400 }
}

/// The network half of a tap's verdict (spec §3).
public enum NetVerdict: Equatable, Sendable {
    /// Nothing the tap caused, or telemetry only (the items, for the telemetry line).
    case none([RequestItem])
    /// A reply the app is still waiting for.
    case pending([RequestItem])
    /// Every reply arrived or failed; a stream that keeps flowing counts as arrived.
    case settled([RequestItem])

    public var items: [RequestItem] {
        switch self {
        case .none(let items), .pending(let items), .settled(let items): return items
        }
    }
}

public enum RequestEvidence {
    /// Joins the two layers. Every log record is an item; it explains one connection to its port (the earliest
    /// unexplained one), whose streaming it takes on. Every connection no record explains is an item of its own (a
    /// non-Apple stack). Telemetry is marked here, never dropped: it gets its own line.
    public static func merge(
        records: [RequestRecord], activity: [FlowActivity], streaming: [FlowActivity], telemetryExtra: [String]
    ) -> [RequestItem] {
        let streams = Set(streaming.map(\.flow.id))
        var unexplained = activity.sorted { $0.flow.openedMs < $1.flow.openedMs }
        var items: [RequestItem] = []
        for r in records {
            var item = RequestItem(
                host: r.host ?? "", port: r.port, path: r.path, status: r.status, errorCode: r.errorCode, ms: r.ms,
                serverMs: r.serverMs, sent: r.sent, received: r.received, proto: r.proto, bodyBytes: r.bodyBytes,
                waiting: !r.finished)
            if let port = r.port, let i = unexplained.firstIndex(where: { $0.flow.remotePort == port }) {
                if streams.contains(unexplained.remove(at: i).flow.id) {
                    item.streaming = true
                    item.waiting = false
                }
            }
            item.telemetry =
                !item.host.isEmpty && Telemetry.isTelemetry(host: item.host, path: item.path, extra: telemetryExtra)
            items.append(item)
        }
        for a in unexplained {
            let streaming = streams.contains(a.flow.id)
            items.append(
                RequestItem(
                    host: a.flow.remoteHost, port: a.flow.remotePort, sent: a.sent, received: a.received,
                    proto: a.flow.proto, waiting: a.waiting && !streaming, streaming: streaming, hostKnown: false))
        }
        return items
    }

    public static func verdict(_ items: [RequestItem]) -> NetVerdict {
        let real = items.filter { !$0.telemetry }
        if real.isEmpty { return .none(items) }
        return real.contains(where: \.waiting) ? .pending(items) : .settled(items)
    }
}
