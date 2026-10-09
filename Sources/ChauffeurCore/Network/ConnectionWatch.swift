import Foundation

/// One connection's part in a tap: the bytes it moved since the touch (M4b spec §2).
public struct FlowActivity: Equatable, Sendable {
    public var flow: Flow
    public var sent: Int
    public var received: Int
    /// Opened after the touch.
    public var isNew: Bool

    /// Bytes went out and nothing has come back on a connection that is still open.
    public var waiting: Bool { flow.isOpen && sent > 0 && received == 0 }
}

public enum ConnectionWatch {
    /// The tap's activity: connections opened after the touch, and connections open before it that sent bytes after
    /// it (HTTP/2 reuses one connection for new requests). A connection already moving bytes between `earlier` (a
    /// sample before the baseline) and `atTouch` is someone else's (a feed loading, polling). Connections that moved no
    /// bytes (address lookups, unused sockets) are dropped.
    public static func activity(earlier: [Flow], atTouch: [Flow], now: [Flow]) -> [FlowActivity] {
        let before = Dictionary(atTouch.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let first = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return now.compactMap { f in
            if let b = before[f.id] {
                if let e = first[f.id], e.tx != b.tx || e.rx != b.rx { return nil }
                let sent = f.tx - b.tx
                guard sent > 0 else { return nil }  // a reply to an earlier request, or a stream opened earlier
                return FlowActivity(flow: f, sent: sent, received: f.rx - b.rx, isNew: false)
            }
            guard f.tx > 0 || f.rx > 0 else { return nil }
            return FlowActivity(flow: f, sent: f.tx, received: f.rx, isNew: true)
        }
    }

    /// Connections that kept receiving between two samples of the same tap without sending: a WebSocket after its
    /// upgrade or a server stream, which wait for nothing (spec §3).
    public static func streaming(previous: [FlowActivity], now: [FlowActivity]) -> [FlowActivity] {
        let earlier = Dictionary(previous.map { ($0.flow.id, $0) }, uniquingKeysWith: { first, _ in first })
        return now.filter { a in
            guard a.flow.isOpen, a.received > 0, let b = earlier[a.flow.id] else { return false }
            return a.received > b.received && a.sent == b.sent
        }
    }
}
