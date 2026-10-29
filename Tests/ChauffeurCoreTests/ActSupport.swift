import Foundation
import Testing

@testable import ChauffeurCore

/// A `FlowSource` that pops one sample per `flows(pids:)` call and holds the last.
@MainActor
final class ScriptedFlows: FlowSource {
    var samples: [[Flow]]
    init(_ samples: [[Flow]]) { self.samples = samples }
    func flows(pids: [Int32]) -> [Flow] { samples.count > 1 ? samples.removeFirst() : samples.first ?? [] }
}

/// The recorded trees, refs and connections the offline `act` tests share (Task 12).
///
/// Reads per observe on the fake clock (`Settle.wait` polls every 75 ms and settles once two consecutive reads agree):
/// a stable screen costs 2 reads at `minMs: 0` and 3 at `minMs: 150`. A first `baseline()` is 4 reads (observe, the
/// 500 ms quiet sleep, observe); one on a screen quiet for 500 ms or more is 2. `act` then reads 3. `ScriptedAX` holds
/// its last frame, so only the frames before it need exact counts.
@MainActor
enum Act {
    static let screen = Size(w: 402, h: 874)
    static let fixtureBundle = "dev.chauffeur.fixture"

    static func udid() -> String { "ZZ" + String(format: "%06X", UInt32.random(in: 0...0xFFFFFF)) + "-TEST" }

    static func home() throws -> AXElement { try Fixtures.ax("fixture-home") }
    static func form() throws -> AXElement { try Fixtures.ax("fixture-form") }
    static func longlist() throws -> AXElement { try Fixtures.ax("fixture-longlist") }
    static func longScrollview() throws -> AXElement { try Fixtures.ax("long-scrollview") }

    /// `long-scrollview` scrolled down 1600 pt: its content moved up and "Label 69" (y 1914 in the recording, below
    /// the 874-pt screen) on screen at y 314; the bars (`AXGroup`) stay where they are.
    static func longScrolled() throws -> AXElement {
        mutated(
            try longScrollview(), where: { $0.role != "AXApplication" && $0.role != "AXGroup" },
            change: { $0.frame.y -= 1600 })
    }

    /// `fixture-form` with the switch ("Agree to terms", `AXSwitch`) on.
    static func formOn() throws -> AXElement {
        mutated(try form(), where: { $0.label == "Agree to terms" }, change: { $0.value = "1" })
    }

    /// `fixture-form` with "alice@example.com" in the email field.
    static func formTyped() throws -> AXElement {
        mutated(try form(), where: { $0.identifier == "email" }, change: { $0.value = "alice@example.com" })
    }

    /// `fixture-form` with 21 bullets in the password field (`TypeCheck.verify` counts the added ones).
    static func formSecure() throws -> AXElement {
        mutated(
            try form(), where: { $0.identifier == "password" },
            change: { $0.value = String(repeating: "•", count: 21) })
    }

    /// `root` with every element that matches changed.
    static func mutated(
        _ root: AXElement, where match: (AXElement) -> Bool, change: (inout AXElement) -> Void
    ) -> AXElement {
        var copy = root
        if match(copy) { change(&copy) }
        copy.children = copy.children.map { mutated($0, where: match, change: change) }
        return copy
    }

    /// The ref the session will give the first element matching `text`, looked up the way the session builds its
    /// first snapshot of `root`: never hard-coded.
    static func ref(_ root: AXElement, _ text: String) throws -> String {
        var refs = RefTable()
        let snap = Perception.build(root: root, size: screen, previous: nil, refs: &refs, rev: 1)
        return try #require(snap.find(text).first?.ref)
    }

    static func flow(rx: Int, closedMs: Int?) -> Flow {
        Flow(
            id: 1, pid: 4321, process: "Fixture", proto: "tcp", remote: "127.0.0.1:8765", tx: 58, rx: rx, openedMs: 1,
            closedMs: closedMs)
    }
    /// A request sent and not answered yet.
    static let waiting = flow(rx: 0, closedMs: nil)
    /// The same request, answered and closed.
    static let done = flow(rx: 512, closedMs: 2)

    /// The recorded `ios27-requests` lines for one task id and its connection, in order.
    static func requestLines(task: String) throws -> [LogLine] {
        let lines = try Fixtures.network("ios27-requests")
        let url = lines.first { $0.message.contains(task) && $0.message.contains("setting up Connection") }
        let connection = url.map { line in line.message.split(separator: " ").last.map { "[C\($0) " } ?? "" } ?? ""
        return lines.filter { line in
            line.message.contains(task) || (!connection.isEmpty && line.message.hasPrefix(connection))
        }
    }

    static func out(_ text: String, status: Int32 = 0) -> ProcessResult {
        ProcessResult(status: status, out: text, timedOut: false)
    }

    /// The shell replies an offline `launch dev.chauffeur.fixture` needs: its Info.plist and its pid, 4321.
    static func launchReplies(udid: String) -> [[String]: [ProcessResult]] {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>Fixture</string>
            <key>CFBundleDisplayName</key><string>Fixture</string>
            </dict></plist>
            """
        return [
            ["appinfo", udid, fixtureBundle]: [out(plist)],
            ["launch", udid, fixtureBundle]: [out("\(fixtureBundle): 4321")],
        ]
    }
}

/// A session over scripted seams, and the fakes behind it, so a test can read what the session did to them.
///
/// The flow source is always there (empty by default), as production's `network.start` builds NetworkStatistics on the
/// first tap: without one, `NetworkPass` would add "network statistics unavailable" to every NO EFFECT.
@MainActor
struct ActRig {
    let s: Session
    let touches: ScriptedTouches
    let shell: RecordingShell
    let clock: FakeClock
    let flows: ScriptedFlows
    let processes: FakeProcesses
    let inputs: FakeInputs
    let logs: ScriptedLogs

    init(
        frames: [AXElement], udid: String = Act.udid(),
        touches: ScriptedTouches = ScriptedTouches(evidence: [.app(Act.fixtureBundle)], attached: true),
        shell: RecordingShell = RecordingShell(), flows: [[Flow]] = [[]],
        processes: FakeProcesses = FakeProcesses(alive: []), inputs: FakeInputs = FakeInputs(),
        logs: ScriptedLogs = ScriptedLogs()
    ) {
        self.touches = touches
        self.shell = shell
        clock = FakeClock()
        self.flows = ScriptedFlows(flows)
        self.processes = processes
        self.inputs = inputs
        self.logs = logs
        s = Session(
            udid: udid,
            environment: .scripted(
                ax: ScriptedAX(frames: frames), touches: touches, shell: shell, clock: clock, flows: self.flows,
                processes: processes, inputs: inputs, logs: logs))
        s.telemetryOverride = []
    }

    /// The output's first line.
    static func head(_ out: Output) -> String { String(out.text.prefix { $0 != "\n" }) }

    /// A context over this rig's session, clock and touch log, as `act` builds one; without a gesture by default.
    func context(
        before: Snapshot, target: Node? = nil, net: TapNet? = nil, capMs: Int = 1500, label: String = "act",
        gesture: ((any TouchTransport) -> Bool)? = nil
    ) -> ActionContext {
        ActionContext(
            label: label, before: before, baselineSettled: true, target: target, capMs: capMs, touchMs: clock.now,
            net: net, expectedApp: s.expectedApp(on: before), isTouchLogAttached: { [touches] in touches.isAttached },
            clock: clock,
            observe: { [s] in try s.observe(minMs: $0, capMs: $1) },
            touchEvidence: { [touches] in touches.evidence(since: $0, waitMs: 200) }, gesture: gesture)
    }
}
