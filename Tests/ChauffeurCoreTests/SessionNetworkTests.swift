import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec §3 through the session's glue, with recorded log lines and scripted connections.
@Suite @MainActor struct SessionNetworkTests {
    func session(
        flows: [[Flow]] = [[]], clock: FakeClock = FakeClock(), telemetry: @escaping (URL) -> [String] = { _ in [] }
    ) -> Session {
        let udid = "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST"
        let environment = SessionEnvironment.scripted(
            ax: ScriptedAX(frames: []), clock: clock, flows: ScriptedFlows(flows), telemetry: telemetry)
        let s = Session(udid: udid, environment: environment)
        // Build the flow source as production's `network.start` has by the time a tap is judged (no pids: no sample).
        _ = s.network.start(appPid: nil) { nil }
        return s
    }

    func report(_ outcome: Outcome) -> ActionReport {
        ActionReport(
            action: "tap e4 \"Login\"", outcome: outcome, evidence: .app("dev.chauffeur.fixture"), settledMs: 400,
            settled: true, revBefore: 3, revAfter: outcome == .changed ? 4 : 3, diff: [], transport: "digitizer",
            retriedFrom: nil, hints: Verifier.hints(outcome: outcome, target: nil), capMs: 1500)
    }

    /// What `NetworkPass` reads of a tap on no element: `net` and the session. The screen is never read.
    func context(_ s: Session, net: TapNet) throws -> ActionContext {
        var refs = RefTable()
        let before = Perception.build(root: try Act.home(), size: Act.screen, previous: nil, refs: &refs, rev: 3)
        return ActionContext(
            label: "tap e4 \"Login\"", before: before, baselineSettled: true, target: nil, capMs: 1500, net: net,
            expectedApp: nil, gesture: nil)
    }

    /// The touch, then `task`'s recorded lines arriving in the log.
    func tap(_ s: Session, task: String) throws -> TapNet {
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logs.cursor, touchMs: s.clock.nowMs())
        for line in try Act.requestLines(task: task) { s.logs.append(line) }
        return net
    }

    @Test func aFailedRequestLeadsTheNoEffect() throws {
        let s = session()
        var r = report(.noEffect)
        try NetworkPass().apply(to: &r, context: context(s, net: try tap(s, task: "A450514C")), session: s)
        #expect(r.outcome == .noEffect)
        #expect(r.render().hasPrefix("tap e4 \"Login\" → NO EFFECT · localhost:8765/fail → 500 Internal Server Error"))
        #expect(r.hints == [RequestText.hint(r.requests[0]) ?? ""])
    }

    @Test func aChangeGetsItsRequestLines() throws {
        let s = session()
        var r = report(.changed)
        try NetworkPass().apply(to: &r, context: context(s, net: try tap(s, task: "F8F70ACA")), session: s)
        #expect(r.outcome == .changed && r.requests.map(\.status) == [201])
    }

    @Test func telemetryOnlyStaysNoEffect() throws {
        let s = session(telemetry: { _ in ["localhost"] })
        var r = report(.noEffect)
        try NetworkPass().apply(to: &r, context: context(s, net: try tap(s, task: "A450514C")), session: s)
        #expect(r.outcome == .noEffect && r.requests.allSatisfy(\.telemetry))
        #expect(r.render().contains("\ntelemetry: 1 request (localhost)"))
        #expect(r.hints == Verifier.hints(outcome: .noEffect, target: nil))
    }

    /// The project's telemetry entries are read for the directory of the client whose command is running.
    @Test func telemetryIsReadForTheRunningCommandsDirectory() throws {
        var dirs: [String] = []
        let s = session(telemetry: { dir in
            dirs.append(dir.path)
            return ["localhost"]
        })
        for project in ["/tmp/project-a", "/tmp/project-b"] {
            dirs = []
            _ = s.run(["find"], cwd: project)  // a usage error: only the directory is kept
            var r = report(.noEffect)
            try NetworkPass().apply(to: &r, context: context(s, net: try tap(s, task: "A450514C")), session: s)
            #expect(!dirs.isEmpty && dirs.allSatisfy { $0 == project }, "\(dirs)")
            let telemetryOnly = r.requests.allSatisfy(\.telemetry)
            #expect(telemetryOnly)
        }
    }

    @Test func aDeadTapStaysPlain() throws {
        let s = session()
        var r = report(.noEffect)
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logs.cursor, touchMs: s.clock.nowMs())
        let started = s.clock.nowMs()
        try NetworkPass().apply(to: &r, context: context(s, net: net), session: s)
        #expect(r.outcome == .noEffect && r.requests.isEmpty)
        #expect(s.clock.nowMs() - started < 200)
    }

    @Test func noProcessMeansNotWatched() throws {
        let s = session()
        var r = report(.noEffect)
        try NetworkPass().apply(
            to: &r, context: context(s, net: TapNet(pids: [], earlier: [], atTouch: [], logCursor: 0, touchMs: 0)),
            session: s)
        #expect(r.networkNote == "no app process to watch")
    }

    @Test func theWindowIsPaidOnTheFakeClockNotTheWall() throws {
        let waiting = Flow(
            id: 1, pid: 4321, process: "Fixture", proto: "tcp", remote: "127.0.0.1:8765", tx: 58,
            rx: 0, openedMs: 1, closedMs: nil)
        let clock = FakeClock()
        let s = session(flows: [[waiting]], clock: clock)
        var r = report(.noEffect)
        let started = Date()
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logs.cursor, touchMs: s.clock.nowMs())
        try NetworkPass().apply(to: &r, context: context(s, net: net), session: s)
        #expect(r.outcome == .pending)
        #expect(clock.now >= NetJudge.requestWindowMs)
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func requestLinesReplaceCFNetworkErrorLinesInLogs() throws {
        let s = session()
        let cursor = s.logs.cursor
        s.logs.append(LogLine(time: "t", level: "error", message: "login failed: invalid token"))
        s.logs.append(
            LogLine(
                time: "t", level: "error",
                message: "Task <AB>.<1> HTTP load failed, 0/0 bytes (error code: -1004 [1:61])",
                sender: "CFNetwork"))
        let withRequests = s.annotate(Output("tap e4", data: ["requests": []]), since: cursor, logs: true)
        #expect(withRequests.text == "tap e4\nlogs: [error] \"login failed: invalid token\"")
        let without = s.annotate(Output("tap e4"), since: cursor, logs: true)
        #expect(without.text.contains("(CFNetwork)"))
    }
}
