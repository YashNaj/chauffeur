import Foundation

extension Session {
    /// Waits stay below the client's reply timeout, so a long wait can't look like a dead daemon (C1).
    nonisolated static let maxWaitSeconds = 300.0
    nonisolated static func waitTimeout(_ seconds: Double?) -> Double {
        min(seconds ?? 10, maxWaitSeconds)
    }

    /// A bare `wait` finishes the last PENDING tap; slow backends take longer than a screen does (M4b spec §9).
    nonisolated static let pendingWaitSeconds = 30.0

    func waitCommand(_ argv: [String]) throws -> Output {
        var a = try Args(
            argv, flags: ["--gone"], options: ["--timeout"],
            usage: "usage: chauffeur wait [\"<query>\"] [--gone] [--timeout <s>]")
        let gone = a.flag("--gone")
        let seconds = try a.number("--timeout", in: 0...86_400)
        guard let query = a.text() else {
            if gone { throw ChauffeurError.usage(a.usage) }
            return try finishPending(
                timeoutMs: Int(min(seconds ?? Self.pendingWaitSeconds, Self.maxWaitSeconds) * 1000))
        }
        let timeout = Self.waitTimeout(seconds)
        let start = clock.nowMs()
        var lastHeader = "no tree yet"
        while true {
            do {
                let snap = try observe(minMs: 0, capMs: 500).snapshot
                lastHeader = snap.header
                let hits = snap.find(query)
                let elapsed = clock.nowMs() - start
                if gone && hits.isEmpty {
                    return Output("gone after \(elapsed)ms", data: ["gone": true, "elapsedMs": JSON(elapsed)])
                }
                if !gone && !hits.isEmpty {
                    return Output(
                        "found after \(elapsed)ms\n"
                            + hits.map { snap.line($0, all: false).trimmingCharacters(in: .whitespaces) }.joined(
                                separator: "\n"),
                        data: [
                            "found": true, "elapsedMs": JSON(elapsed),
                            "matches": .array(hits.map { $0.json(all: false) }),
                        ])
                }
            } catch let error as ChauffeurError where error.appNotUpYet {
                // app still launching; keep waiting
            }
            if Double(clock.nowMs() - start) >= timeout * 1000 {
                return Output(
                    (gone ? "still present" : "not found") + " after \(Geometry.fmt(timeout))s: "
                        + Perception.quote(query) + "\nscreen: " + lastHeader
                        + (stillWaiting().map { "\nstill waiting: " + $0 } ?? ""), exit: .notFound,
                    data: [gone ? "gone" : "found": false, "screen": .string(lastHeader)])
            }
            clock.sleep(ms: 100)
        }
    }

    /// Waits for the PENDING tap's replies, then judges the tap again with the screen as it is now (spec §9).
    func finishPending(timeoutMs: Int) throws -> Output {
        guard let pending = pendingTap else {
            return Output(
                "nothing to wait for: no tap came back PENDING since the last action. To wait for something on the "
                    + "screen: chauffeur wait \"<text>\"", exit: .error)
        }
        let start = clock.nowMs()
        var previous: [FlowActivity] = []
        var verdict = RequestEvidence.verdict(netItems(pending.net, previous: &previous))
        while case .pending = verdict, clock.nowMs() - start < timeoutMs {
            clock.sleep(ms: 200)
            verdict = RequestEvidence.verdict(netItems(pending.net, previous: &previous))
        }
        let (after, settle) = try observe(minMs: 150, capMs: 1500)
        var report = pending.report
        report.requests = verdict.items
        report.requestElapsedMs = clock.nowMs() - pending.net.touchMs
        report.evidenceShot = nil
        if after.hash != pending.before.hash {
            report.outcome = .changed
            report.revAfter = after.rev
            report.diff = Diff.lines(from: pending.before, to: after)
            report.settledMs = settle.elapsedMs
            report.settled = settle.settled
            report.hints = []
        } else if case .pending = verdict {
            report.outcome = .pending
            report.hints = Verifier.hints(outcome: .pending, target: pending.target)
        } else {
            report.outcome = .noEffect
            report.hints =
                ActionReport.lead(verdict.items, pending: false).flatMap(RequestText.hint).map { [$0] }
                ?? Verifier.hints(outcome: .noEffect, target: pending.target)
        }
        if report.outcome == .pending { pendingTap?.report = report } else { pendingTap = nil }
        return Output(report.render(), exit: report.exitCode, data: report.json)
    }

    /// `api.example.com/feed (9.8 s)` for each reply the last action is still waiting for; nil when none is.
    func stillWaiting() -> String? {
        if let pending = pendingTap {
            var previous: [FlowActivity] = []
            let elapsed = RequestText.duration(clock.nowMs() - pending.net.touchMs)
            let open = netItems(pending.net, previous: &previous).filter { $0.waiting && !$0.telemetry }
            return open.isEmpty ? nil : open.map { RequestText.target($0) + " (\(elapsed))" }.joined(separator: ", ")
        }
        let open = RequestLog.parse(logs.since(lastActionLogCursor)).filter { !$0.finished && $0.host != nil }
        let items = RequestEvidence.merge(records: open, activity: [], streaming: [], telemetryExtra: telemetryHosts())
            .filter { !$0.telemetry }
        return items.isEmpty ? nil : items.map(RequestText.target).joined(separator: ", ")
    }
}
