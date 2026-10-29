import Foundation
import Testing

@testable import ChauffeurCore

final class FakeClock: SettleClock {
    var now = 0
    func nowMs() -> Int { now }
    func sleep(ms: Int) { now += ms }
}

enum Fixtures {
    /// An accessibility tree recorded in M0 (`spikes/fixtures/ax`).
    static func ax(_ name: String) throws -> AXElement {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ax"))
        return try JSONDecoder().decode(AXElement.self, from: Data(contentsOf: url))
    }

    /// A crash report trimmed from the M0 fixture crash (`Fixtures/crash`).
    static func crash(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "ips", subdirectory: "Fixtures/crash"))
        return try Data(contentsOf: url)
    }

    /// Apple networking log lines recorded in M4b step 0 (`Fixtures/network`), as `LogTap` stores them.
    static func network(_ name: String) throws -> [LogLine] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/network"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { row in
            let o = try #require(try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: String])
            return LogRedact.line(
                LogLine(
                    time: "00:00:00.000", level: o["level"] ?? "default", message: o["message"] ?? "",
                    sender: o["sender"]))
        }
    }
}

/// Finds the first element whose label, identifier or value contains `text`.
func element(_ root: AXElement, _ text: String) -> AXElement? {
    root.all.first { e in
        [e.label, e.identifier, e.value].contains { $0?.localizedCaseInsensitiveContains(text) == true }
    }
}

/// An `AXSource` that replays recorded trees: each `read()` returns the next frame and holds the last.
@MainActor
final class ScriptedAX: AXSource {
    private let frames: [AXElement?]
    private var next = 0
    var scriptedPID: Int32? = 4321
    /// Runs at each `read()`, before the frame is handed out: for something that happens while the screen is read.
    var onRead: (() -> Void)?

    init(frames: [AXElement?]) { self.frames = frames }

    func read() -> AXElement? {
        onRead?()
        guard !frames.isEmpty else { return nil }
        defer { next = min(next + 1, frames.count - 1) }
        return frames[next]
    }
    func read(pid: Int32) -> AXElement? { nil }
    func frontmostPID() -> Int32? { scriptedPID }
    func element(at point: Point) -> AXElement? { nil }
    func probe(center: Point) -> (frontmostIsEmptyApp: Bool, screenAnswers: Bool) { (false, true) }
    func complete(_ root: AXElement) -> AXElement { root }
}

/// A `SimDevice` with fixed answers.
@MainActor
final class FakeDevice: SimDevice {
    let udid: String
    var booted: Bool
    var size: Size

    init(udid: String, booted: Bool, size: Size) {
        self.udid = udid
        self.booted = booted
        self.size = size
    }
}

/// A `TouchEvidenceSource` that replays scripted evidence: each `evidence(since:waitMs:)` returns the next entry and
/// holds the last (`.none` when the script is empty), or `.unavailable` while detached. `cursor` counts the recorded
/// touches handed out so far (entries other than `.none`), as the real log's cursor counts records.
final class ScriptedTouches: TouchEvidenceSource {
    private let script: [Evidence]
    private var next = 0
    private(set) var cursor = 0
    /// Every `evidence(since:waitMs:)` call's arguments, so a test can prove which cursor a caller passed.
    private(set) var requests: [(since: Int, waitMs: Int)] = []
    /// Settable, so a test can stop the log mid-action, as a reconnect's `drop()` does.
    var isAttached: Bool

    init(evidence: [Evidence], attached: Bool) {
        script = evidence
        isAttached = attached
    }

    func start() throws {}
    func stop() {}

    func evidence(since cursor: Int, waitMs: Int) -> Evidence {
        requests.append((since: cursor, waitMs: waitMs))
        guard isAttached else { return .unavailable }
        guard !script.isEmpty else { return .none }
        let evidence = script[next]
        next = min(next + 1, script.count - 1)
        if evidence != .none { self.cursor += 1 }
        return evidence
    }
}

/// A `ShellRunner` that records every call and answers from a table keyed by args. A key holds its replies in order,
/// for a repeated call (`pbpaste` before and after a tap); the last one holds. Calls arrive from whichever thread
/// `Session` runs a command on, so the state is lock-guarded (`@unchecked Sendable`, as `Box` in `Shell.swift`).
final class RecordingShell: ShellRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(args: [String], stdin: String?, timeout: Double)] = []
    private var served: [[String]: Int] = [:]
    private let replies: [[String]: [ProcessResult]]

    init(replies: [[String]: [ProcessResult]] = [:]) { self.replies = replies }

    var calls: [[String]] { lock.withLock { log.map(\.args) } }
    /// Every call with the stdin and timeout it passed (Task 12 asserts pbcopy's stdin).
    var recorded: [(args: [String], stdin: String?, timeout: Double)] { lock.withLock { log } }

    func simctl(_ args: [String], stdin: String?, timeout: Double) throws -> ProcessResult {
        let reply: ProcessResult = lock.withLock {
            log.append((args: args, stdin: stdin, timeout: timeout))
            let index = served[args, default: 0]
            served[args] = index + 1
            guard let ordered = replies[args], let last = ordered.indices.last else {
                return ProcessResult(status: 0, out: "", timedOut: false)
            }
            return ordered[min(index, last)]
        }
        if reply.timedOut {
            // As `SimCtl.run` does.
            throw ChauffeurError.simulatorServiceUnresponsive(
                command: "simctl " + args.prefix(2).joined(separator: " "))
        }
        return reply
    }
}

extension SessionEnvironment {
    /// Tests: scripts the device, accessibility, touch evidence, shell, clock, flows, processes, boot state, the
    /// crash report, the input device and the launched app's log. By default the touch log is unattached, there are no flows or live
    /// processes, the simulator is booted (no boot date), no crash report is found, the input device's two transports
    /// and keyboard send, the log is empty and attaches, and the device is booted at 402×874. It does not fake the
    /// `StatePaths` files under `$TMPDIR/chauffeur`; the session still uses those.
    @MainActor
    static func scripted(
        ax: ScriptedAX, touches: ScriptedTouches = ScriptedTouches(evidence: [], attached: false),
        shell: RecordingShell = RecordingShell(), clock: FakeClock = FakeClock(),
        flows: (any FlowSource)? = nil, processes: FakeProcesses = FakeProcesses(alive: []),
        simulatorBooted: @escaping () -> Bool? = { true }, simulatorBootDate: @escaping () -> Date? = { nil },
        findCrashReport: @escaping (TrackedApp) -> CrashReport? = { _ in nil },
        inputs: FakeInputs = FakeInputs(), logs: ScriptedLogs = ScriptedLogs()
    ) -> SessionEnvironment {
        nonisolated(unsafe) let flows = flows  // a test's own object, only ever read on the main actor
        return SessionEnvironment(
            clock: clock,
            device: { FakeDevice(udid: $0, booted: true, size: Size(w: 402, h: 874)) },
            ax: { _ in ax },
            touchEvidence: touches,
            shell: shell,
            flows: { flows },
            processes: processes,
            simulatorBooted: simulatorBooted,
            simulatorBootDate: simulatorBootDate,
            findCrashReport: findCrashReport,
            inputs: { _ in inputs },
            logs: logs)
    }
}

/// A `LogSource` over a `LogRing`: `start` records the executable and attaches, or not (`attaches: false`, a
/// `log stream` that never came up); tests feed lines with `append`, shaped as `LogTap` stores them.
final class ScriptedLogs: LogSource {
    private var ring = LogRing(capacity: 2000)
    /// Lines that land in the ring at the next `since(_:)` call, shaped as `append` shapes them: for a tap, after the
    /// cursor taken at the touch.
    var arriving: [LogLine] = []
    private let attaches: Bool
    private(set) var isAttached = false
    private(set) var executable: String?
    /// Every executable `start` was asked to follow, in order.
    private(set) var started: [String] = []

    init(attaches: Bool = true) { self.attaches = attaches }

    var cursor: Int { ring.end }
    var all: [LogLine] { ring.lines }
    func since(_ cursor: Int) -> [LogLine] {
        arriving.forEach(append)
        arriving = []
        return ring.since(cursor)
    }

    @discardableResult
    func start(executable: String) -> Bool {
        started.append(executable)
        self.executable = executable
        isAttached = attaches
        return attaches
    }

    func stop() { isAttached = false }
    func append(_ line: LogLine) { ring.append(LogRedact.line(line)) }
}

/// A `ProcessTable` whose live pids a test changes between commands (a reference, so the session sees the change).
/// Nobody has relatives.
final class FakeProcesses: ProcessTable, @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<Int32>

    init(alive: Set<Int32>) { pids = alive }

    var alive: Set<Int32> {
        get { lock.withLock { pids } }
        set { lock.withLock { pids = newValue } }
    }

    func isAlive(_ pid: Int32) -> Bool { alive.contains(pid) }
    func parent(of pid: Int32) -> Int32? { nil }
    func children(of parent: Int32, named: String) -> [Int32] { [] }
}

/// A `TouchTransport` that records every touch and answers `sends`.
@MainActor
final class FakeTransport: TouchTransport {
    let name: String
    let supportsMove: Bool
    /// Whether `touch` sends; a test can flip it between actions.
    var sends: Bool
    private(set) var touches: [(Point, TouchPhase)] = []

    init(name: String, supportsMove: Bool, sends: Bool = true) {
        self.name = name
        self.supportsMove = supportsMove
        self.sends = sends
    }

    func touch(_ normalised: Point, _ phase: TouchPhase) -> Bool {
        touches.append((normalised, phase))
        return sends
    }
}

/// A `TextInput` that records what it typed and pressed. `press` answers the next of `presses` and holds the last.
final class FakeTextInput: TextInput {
    private let types: Bool
    private let presses: [Bool]
    private(set) var typed: [String] = []
    private(set) var pressed: [(usage: UInt32, modifiers: [UInt32])] = []

    init(types: Bool = true, presses: [Bool] = [true]) {
        self.types = types
        self.presses = presses
    }

    func type(_ text: String) -> Bool {
        typed.append(text)
        return types
    }

    func press(_ usage: UInt32, modifiers: [UInt32]) -> Bool {
        let index = pressed.count
        pressed.append((usage: usage, modifiers: modifiers))
        guard let last = presses.indices.last else { return true }
        return presses[min(index, last)]
    }
}

/// An `InputDevice` over fakes: the same transports until the end (it counts resets rather than rebuilding), a
/// scripted keyboard, and buttons that record their press and hold it on the clock as `HID` does.
@MainActor
final class FakeInputs: InputDevice {
    let fakes: [FakeTransport]
    let keyboard: FakeTextInput
    private let pressAnswer: Bool
    private(set) var resetCount = 0
    private(set) var pressed: [HardwareButton] = []

    init(
        transports: [FakeTransport] = [
            FakeTransport(name: "digitizer", supportsMove: true), FakeTransport(name: "mouse", supportsMove: false),
        ],
        keyboard: FakeTextInput = FakeTextInput(), press: Bool = true
    ) {
        fakes = transports
        self.keyboard = keyboard
        pressAnswer = press
    }

    func transports() throws -> [any TouchTransport] { fakes }
    func keyboard(clock: any SettleClock) throws -> any TextInput { keyboard }

    func press(_ button: HardwareButton, clock: any SettleClock) throws -> Bool {
        pressed.append(button)
        clock.sleep(ms: button.holdMs)
        return pressAnswer
    }

    func reset() { resetCount += 1 }
}
