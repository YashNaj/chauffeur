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

extension Session {
    /// The processes whose traffic is the app's: the launched app (else the app in front) and the simulator's WebKit
    /// networking process, its sibling under the device's launchd_sim, for web views (Findings §2).
    func watchedPids() -> [Int32] {
        guard let pid = app?.pid ?? ax?.frontmostPID() else { return [] }
        let webKit = Proc.parent(pid).map { Proc.children(of: $0, named: "com.apple.WebKit.Networking") } ?? []
        return [pid] + webKit
    }

    func flows(_ pids: [Int32]) -> [Flow] {
        if flowSource == nil, !flowSourceTried {
            flowSourceTried = true
            flowSource = try? NetStatsSource()
        }
        guard let flowSource, !pids.isEmpty else { return [] }
        return flowSource.flows(pids: pids)
    }

    func netStart() -> NetStart {
        let pids = watchedPids()
        return NetStart(pids: pids, earlier: flows(pids))
    }

    /// Right before the touch.
    func tapNet(_ start: NetStart) -> TapNet {
        TapNet(
            pids: start.pids, earlier: start.earlier, atTouch: flows(start.pids), logCursor: logTap.cursor,
            touchMs: clock.nowMs())
    }

    func telemetryHosts() -> [String] { telemetryOverride ?? Target.telemetryHosts(from: resolvePath(".")) }

    /// Both layers now, merged. `previous` is the last sample's activity, to tell a stream from a reply.
    func netItems(_ net: TapNet, previous: inout [FlowActivity]) -> [RequestItem] {
        let activity = ConnectionWatch.activity(earlier: net.earlier, atTouch: net.atTouch, now: flows(net.pids))
        let streaming = ConnectionWatch.streaming(previous: previous, now: activity)
        previous = activity
        return RequestEvidence.merge(
            records: RequestLog.parse(logTap.since(net.logCursor)), activity: activity, streaming: streaming,
            telemetryExtra: telemetryHosts())
    }

    /// Spec §3: a NO EFFECT may become PENDING or carry the reply that explains it; a change gets its request lines.
    /// Other outcomes (delivery problems) are left alone.
    func applyNetwork(_ report: inout ActionReport, net: TapNet, target: Node?) {
        guard report.outcome == .noEffect || report.outcome == .changed else { return }
        if report.outcome == .noEffect, net.pids.isEmpty || flowSource == nil {
            report.networkNote = net.pids.isEmpty ? "no app process to watch" : "network statistics unavailable"
        }
        var previous: [FlowActivity] = []
        let verdict: NetVerdict
        if report.outcome == .changed {
            clock.sleep(ms: NetJudge.graceMs)
            verdict = RequestEvidence.verdict(netItems(net, previous: &previous))
        } else {
            let textField = target.map { Perception.textEntry.contains($0.role) } ?? false
            verdict = NetJudge.judge(
                clock: clock, touchMs: net.touchMs, extraWindowMs: textField ? NetJudge.textFieldWindowMs : 0
            ) {
                netItems(net, previous: &previous)
            }
        }
        report.requests = verdict.items
        report.requestElapsedMs = clock.nowMs() - net.touchMs
        guard report.outcome == .noEffect else { return }
        switch verdict {
        case .none:
            break
        case .pending:
            report.outcome = .pending
            report.hints = Verifier.hints(outcome: .pending, target: target)
        case .settled(let items):
            if let hint = ActionReport.lead(items, pending: false).flatMap(RequestText.hint) { report.hints = [hint] }
        }
    }

    /// Spec §3: a reply arrived inside the request window, so the screen is judged again as it is now. Without this,
    /// a response the app draws after its reply would be a false NO EFFECT.
    func judgeScreenAgain(_ report: inout ActionReport, before: Snapshot, net: TapNet, capMs: Int) throws {
        guard report.outcome == .noEffect, report.requests.contains(where: { !$0.telemetry }) else { return }
        let (again, settle) = try observe(minMs: 150, capMs: capMs)
        guard again.hash != before.hash else { return }
        report.outcome = .changed
        report.revAfter = again.rev
        report.diff = Diff.lines(from: before, to: again)
        report.settledMs = clock.nowMs() - net.touchMs
        report.settled = settle.settled
        report.hints = []
    }
}
