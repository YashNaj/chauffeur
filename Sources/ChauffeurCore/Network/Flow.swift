import ChauffeurBridge
import Foundation

/// One connection of a watched process: what the activity layer sees (M4b spec §2).
public struct Flow: Equatable, Sendable {
    public var id: Int
    public var pid: Int32
    public var process: String
    /// `tcp` or `udp`.
    public var proto: String
    /// `ip:port` (`[ip]:port` for IPv6); empty until the connection has a remote address.
    public var remote: String
    public var tx: Int
    public var rx: Int
    /// Uptime milliseconds, the clock `SystemClock` reads.
    public var openedMs: Int
    public var closedMs: Int?

    public init(
        id: Int, pid: Int32, process: String, proto: String, remote: String, tx: Int, rx: Int, openedMs: Int,
        closedMs: Int?
    ) {
        (self.id, self.pid, self.process, self.proto, self.remote) = (id, pid, process, proto, remote)
        (self.tx, self.rx, self.openedMs, self.closedMs) = (tx, rx, openedMs, closedMs)
    }

    /// A flow as `CHNetStats` reports it; nil without an id and a pid.
    init?(dictionary d: [String: Any]) {
        guard let id = (d["id"] as? NSNumber)?.intValue, let pid = (d["pid"] as? NSNumber)?.int32Value else {
            return nil
        }
        self.init(
            id: id, pid: pid, process: d["process"] as? String ?? "",
            proto: (d["provider"] as? String ?? "").lowercased(), remote: d["remote"] as? String ?? "",
            tx: (d["tx"] as? NSNumber)?.intValue ?? 0, rx: (d["rx"] as? NSNumber)?.intValue ?? 0,
            openedMs: (d["openedMs"] as? NSNumber)?.intValue ?? 0, closedMs: (d["closedMs"] as? NSNumber)?.intValue)
    }

    public var isOpen: Bool { closedMs == nil }

    public var remoteHost: String {
        if remote.hasPrefix("["), let close = remote.firstIndex(of: "]") {
            return String(remote[remote.index(after: remote.startIndex)..<close])
        }
        return remote.lastIndex(of: ":").map { String(remote[..<$0]) } ?? remote
    }

    public var remotePort: Int? { remote.lastIndex(of: ":").flatMap { Int(remote[remote.index(after: $0)...]) } }
}

/// Where flows come from: the NetworkStatistics bridge in the daemon, a scripted list in tests.
@MainActor
public protocol FlowSource: AnyObject {
    func flows(pids: [Int32]) -> [Flow]
}

@MainActor
public final class NetStatsSource: FlowSource {
    private let stats: CHNetStats

    public init() throws {
        do { stats = try CHNetStats.open() } catch { throw ChauffeurError.bridge(error.localizedDescription) }
    }

    public func flows(pids: [Int32]) -> [Flow] {
        stats.flows(pids: pids.map { NSNumber(value: $0) }).compactMap(Flow.init(dictionary:))
    }
}
