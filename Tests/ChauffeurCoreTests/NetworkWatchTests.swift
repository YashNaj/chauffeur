import Foundation
import Testing

@testable import ChauffeurCore

/// The network watch on its own (spec §3): scripted connections and log lines, the fake clock. The report shape
/// these verdicts lead to is `PassTests`'s.
@Suite @MainActor struct NetworkWatchTests {
    let clock = FakeClock()
    let logs = ScriptedLogs()

    func watch(flows: [[Flow]] = [[]]) -> NetworkWatch {
        let source = ScriptedFlows(flows)
        return NetworkWatch(
            flows: { source }, processes: FakeProcesses(alive: []), logs: logs, clock: clock, telemetry: { _ in [] })
    }

    /// The touch on the app (pid 4321), before any connection of its was seen.
    func touch() -> TapNet {
        TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: logs.cursor, touchMs: clock.now)
    }

    func pending(_ net: TapNet) throws -> PendingTap {
        var refs = RefTable()
        let before = Perception.build(root: try Act.home(), size: Act.screen, previous: nil, refs: &refs, rev: 3)
        let report = ActionReport(
            action: "tap e4 \"Login\"", outcome: .pending, evidence: .app(Act.fixtureBundle), settledMs: 400,
            settled: true, revBefore: 3, revAfter: 3, diff: [], transport: "digitizer", retriedFrom: nil,
            hints: Verifier.hints(outcome: .pending, target: nil), capMs: 1500)
        return PendingTap(report: report, before: before, net: net, target: nil)
    }

    @Test func aRequestWithNoReplyIsPending() {
        let w = watch(flows: [[Act.waiting]])
        let verdict = w.judge(afterTouch: touch(), textField: false)
        guard case .pending(let items) = verdict else {
            Issue.record("expected pending, got \(verdict)")
            return
        }
        #expect(items.map(RequestText.target) == ["127.0.0.1:8765"] && items.allSatisfy(\.waiting))
        #expect(clock.now == NetJudge.graceMs + NetJudge.requestWindowMs)
    }

    @Test func aFailedReplySettlesWithIts500() throws {
        let w = watch()
        let net = touch()
        for line in try Act.requestLines(task: "A450514C") { logs.append(line) }
        let verdict = w.judge(afterTouch: net, textField: false)
        guard case .settled(let items) = verdict else {
            Issue.record("expected settled, got \(verdict)")
            return
        }
        #expect(items.map(\.status) == [500])
        #expect(items.map(RequestText.target) == ["localhost:8765/fail"])
    }

    /// `wait "<text>"` that times out names what the pending tap is still waiting for, and since when.
    @Test func stillWaitingNamesThePendingTapsOpenRequest() throws {
        let w = watch(flows: [[Act.waiting]])
        w.pending = try pending(touch())
        clock.now = 9800
        #expect(w.stillWaiting(sinceLogCursor: 0) == "127.0.0.1:8765 (9.8 s)")
    }

    @Test func stillWaitingIsNilWhenNothingIsOpen() throws {
        let w = watch(flows: [[Act.done]])
        #expect(w.stillWaiting(sinceLogCursor: 0) == nil)
        w.pending = try pending(touch())
        #expect(w.stillWaiting(sinceLogCursor: 0) == nil)
    }
}
