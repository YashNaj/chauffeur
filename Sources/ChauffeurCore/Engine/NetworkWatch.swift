import Foundation

/// A tap's first network sample, taken before the baseline: a connection already moving bytes then isn't the tap's.
struct NetStart {
    var pids: [Int32]
    var earlier: [Flow]
}

/// A tap's network state at the touch: enough to judge it now and again from a bare `wait`.
struct TapNet {
    var pids: [Int32]
    var earlier: [Flow]
    var atTouch: [Flow]
    var logCursor: Int
    var touchMs: Int
}

/// A tap that came back PENDING (M4b spec §9).
struct PendingTap {
    var report: ActionReport
    var before: Snapshot
    var net: TapNet
    var target: Node?
}

/// One owner of the flow source, the watched pids, the telemetry list and the pending tap (spec §3).
@MainActor
final class NetworkWatch {
    private let flowsSource: @MainActor () -> (any FlowSource)?
    private let processes: any ProcessTable
    private let logs: any LogSource
    private let clock: any SettleClock
    private let telemetry: (URL) -> [String]
    /// The activity layer (M4b spec §2), built on the first sample; nil when NetworkStatistics is unavailable.
    private var flowSource: (any FlowSource)?
    private var flowSourceTried = false
    /// The client's project directory, whose telemetry entries count: the session sets it for each command
    /// (`Session.run`). Until then, the daemon's own directory, as a command without a client directory resolves it.
    var projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    /// The last tap that came back PENDING, for a bare `wait` (M4b spec §9); any logged command forgets it (`runOne`).
    var pending: PendingTap?

    init(
        flows: @escaping @MainActor () -> (any FlowSource)?, processes: any ProcessTable, logs: any LogSource,
        clock: any SettleClock, telemetry: @escaping (URL) -> [String]
    ) {
        flowsSource = flows
        self.processes = processes
        self.logs = logs
        self.clock = clock
        self.telemetry = telemetry
    }

    /// The watched pids and the first sample.
    func start(appPid: Int32?, frontmost: () -> Int32?) -> NetStart {
        let pids = watchedPids(appPid: appPid, frontmost: frontmost)
        return NetStart(pids: pids, earlier: flows(pids))
    }

    /// The processes whose traffic is the app's: the launched app (else the app in front, asked only without one) and
    /// the simulator's WebKit networking process, its sibling under the device's launchd_sim, for web views
    /// (Findings §2).
    private func watchedPids(appPid: Int32?, frontmost: () -> Int32?) -> [Int32] {
        guard let pid = appPid ?? frontmost() else { return [] }
        let webKit =
            processes.parent(of: pid).map { processes.children(of: $0, named: "com.apple.WebKit.Networking") } ?? []
        return [pid] + webKit
    }

    /// Right before the touch.
    func atTouch(_ start: NetStart) -> TapNet {
        TapNet(
            pids: start.pids, earlier: start.earlier, atTouch: flows(start.pids), logCursor: logs.cursor,
            touchMs: clock.nowMs())
    }

    /// Why a NO EFFECT's network could not be watched, if it could not.
    func unavailableNote(_ net: TapNet) -> String? {
        if net.pids.isEmpty { return "no app process to watch" }
        return flowSource == nil ? "network statistics unavailable" : nil
    }

    /// `NetJudge.judge` over the tap's requests; a text field also waits for a debounced request.
    func judge(afterTouch net: TapNet, textField: Bool) -> NetVerdict {
        var previous: [FlowActivity] = []
        return NetJudge.judge(
            clock: clock, touchMs: net.touchMs, extraWindowMs: textField ? NetJudge.textFieldWindowMs : 0
        ) {
            netItems(net, previous: &previous)
        }
    }

    /// The grace, then one look at both layers.
    func sampleOnce(_ net: TapNet) -> [RequestItem] {
        clock.sleep(ms: NetJudge.graceMs)
        var previous: [FlowActivity] = []
        return netItems(net, previous: &previous)
    }

    /// `NetJudge.finish` over the tap's requests: a bare `wait`, its timeout counted from now.
    func finish(_ net: TapNet, timeoutMs: Int) -> NetVerdict {
        var previous: [FlowActivity] = []
        return NetJudge.finish(clock: clock, timeoutMs: timeoutMs) { netItems(net, previous: &previous) }
    }

    /// `api.example.com/feed (9.8 s)` for each reply the pending tap is still waiting for; without one, the requests
    /// logged since `sinceLogCursor` that never finished. Nil when none is open.
    func stillWaiting(sinceLogCursor cursor: Int) -> String? {
        if let pending {
            var previous: [FlowActivity] = []
            let elapsed = RequestText.duration(clock.nowMs() - pending.net.touchMs)
            let open = netItems(pending.net, previous: &previous).filter { $0.waiting && !$0.telemetry }
            return open.isEmpty ? nil : open.map { RequestText.target($0) + " (\(elapsed))" }.joined(separator: ", ")
        }
        let open = RequestLog.parse(logs.since(cursor)).filter { !$0.finished && $0.host != nil }
        let items = RequestEvidence.merge(
            records: open, activity: [], streaming: [], telemetryExtra: telemetry(projectDir)
        )
        .filter { !$0.telemetry }
        return items.isEmpty ? nil : items.map(RequestText.target).joined(separator: ", ")
    }

    /// The flow source is built on the first sample, at most once.
    private func flows(_ pids: [Int32]) -> [Flow] {
        if flowSource == nil, !flowSourceTried {
            flowSourceTried = true
            flowSource = flowsSource()
        }
        guard let flowSource, !pids.isEmpty else { return [] }
        return flowSource.flows(pids: pids)
    }

    /// Both layers now, merged. `previous` is the last sample's activity, to tell a stream from a reply.
    private func netItems(_ net: TapNet, previous: inout [FlowActivity]) -> [RequestItem] {
        let activity = ConnectionWatch.activity(earlier: net.earlier, atTouch: net.atTouch, now: flows(net.pids))
        let streaming = ConnectionWatch.streaming(previous: previous, now: activity)
        previous = activity
        return RequestEvidence.merge(
            records: RequestLog.parse(logs.since(net.logCursor)), activity: activity, streaming: streaming,
            telemetryExtra: telemetry(projectDir))
    }
}
