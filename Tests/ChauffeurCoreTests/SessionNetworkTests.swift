import Foundation
import Testing

@testable import ChauffeurCore

@MainActor
final class ScriptedFlows: FlowSource {
    var samples: [[Flow]]
    init(_ samples: [[Flow]]) { self.samples = samples }
    func flows(pids: [Int32]) -> [Flow] { samples.count > 1 ? samples.removeFirst() : samples.first ?? [] }
}

/// M4b spec §3 through the session's glue, with recorded log lines and scripted connections.
@Suite @MainActor struct SessionNetworkTests {
    func session(flows: [[Flow]] = [[]]) -> Session {
        let s = Session(udid: "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST")
        s.flowSource = ScriptedFlows(flows)
        s.flowSourceTried = true
        s.telemetryOverride = []
        return s
    }

    func report(_ outcome: Outcome) -> ActionReport {
        ActionReport(
            action: "tap e4 \"Login\"", outcome: outcome, evidence: .app("dev.chauffeur.fixture"), settledMs: 400,
            settled: true, revBefore: 3, revAfter: outcome == .changed ? 4 : 3, diff: [], transport: "digitizer",
            retriedFrom: nil, hints: Verifier.hints(outcome: outcome, target: nil), capMs: 1500)
    }

    /// The touch, then `task`'s recorded lines arriving in the log.
    func tap(_ s: Session, task: String) throws -> TapNet {
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logTap.cursor, touchMs: s.clock.nowMs())
        let lines = try Fixtures.network("ios27-requests")
        let url = lines.first { $0.message.contains(task) && $0.message.contains("setting up Connection") }
        let connection = url.map { line in line.message.split(separator: " ").last.map { "[C\($0) " } ?? "" } ?? ""
        for line in lines
        where line.message.contains(task) || (!connection.isEmpty && line.message.hasPrefix(connection)) {
            s.logTap.append(line)
        }
        return net
    }

    @Test func aFailedRequestLeadsTheNoEffect() throws {
        let s = session()
        var r = report(.noEffect)
        s.applyNetwork(&r, net: try tap(s, task: "A450514C"), target: nil)
        #expect(r.outcome == .noEffect)
        #expect(r.render().hasPrefix("tap e4 \"Login\" → NO EFFECT · localhost:8765/fail → 500 Internal Server Error"))
        #expect(r.hints == [RequestText.hint(r.requests[0]) ?? ""])
    }

    @Test func aChangeGetsItsRequestLines() throws {
        let s = session()
        var r = report(.changed)
        s.applyNetwork(&r, net: try tap(s, task: "F8F70ACA"), target: nil)
        #expect(r.outcome == .changed && r.requests.map(\.status) == [201])
    }

    @Test func telemetryOnlyStaysNoEffect() throws {
        let s = session()
        s.telemetryOverride = ["localhost"]
        var r = report(.noEffect)
        s.applyNetwork(&r, net: try tap(s, task: "A450514C"), target: nil)
        #expect(r.outcome == .noEffect && r.requests.allSatisfy(\.telemetry))
        #expect(r.render().contains("\ntelemetry: 1 request (localhost)"))
        #expect(r.hints == Verifier.hints(outcome: .noEffect, target: nil))
    }

    @Test func aDeadTapStaysPlain() {
        let s = session()
        var r = report(.noEffect)
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logTap.cursor, touchMs: s.clock.nowMs())
        let started = s.clock.nowMs()
        s.applyNetwork(&r, net: net, target: nil)
        #expect(r.outcome == .noEffect && r.requests.isEmpty)
        #expect(s.clock.nowMs() - started < 200)
    }

    @Test func noProcessMeansNotWatched() {
        let s = session()
        var r = report(.noEffect)
        s.applyNetwork(&r, net: TapNet(pids: [], earlier: [], atTouch: [], logCursor: 0, touchMs: 0), target: nil)
        #expect(r.networkNote == "no app process to watch")
    }

    @Test func aRawSocketWaitingIsPending() {
        let waiting = Flow(
            id: 1, pid: 4321, process: "Fixture", proto: "tcp", remote: "127.0.0.1:8765", tx: 58,
            rx: 0, openedMs: 1, closedMs: nil)
        let s = session(flows: [[waiting]])
        var r = report(.noEffect)
        let net = TapNet(pids: [4321], earlier: [], atTouch: [], logCursor: s.logTap.cursor, touchMs: s.clock.nowMs())
        s.applyNetwork(&r, net: net, target: nil)
        #expect(r.outcome == .pending && r.exitCode == .pending)
        #expect(r.render().hasPrefix("tap e4 \"Login\" → PENDING · 127.0.0.1:8765 · sent 58 B, no reply after 2."))
    }

    @Test func requestLinesReplaceCFNetworkErrorLinesInLogs() throws {
        let s = session()
        let cursor = s.logTap.cursor
        s.logTap.append(LogLine(time: "t", level: "error", message: "login failed: invalid token"))
        s.logTap.append(
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
