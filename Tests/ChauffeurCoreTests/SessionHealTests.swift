import Foundation
import Testing

@testable import ChauffeurCore

/// `heal` offline: its simctl calls go through the session's `ShellRunner`, so a scripted shell sees every one.
///
/// `connect()` already runs `ensureAccessibility(force: false)` through the shell before any read, so a `defaults read`
/// or a first `defaults write` proves nothing about `heal`. These tests assert the evidence only `heal` produces.
@Suite @MainActor struct SessionHealTests {
    private let udid = "ZZ000000-TEST"

    /// `AXSettings.off` parses the output of `defaults read` as a property list.
    private func defaultsRead(_ value: Int, for keys: [String]) -> ProcessResult {
        ProcessResult(
            status: 0, out: "{ " + keys.map { "\($0) = \(value);" }.joined(separator: " ") + " }", timedOut: false)
    }

    @Test func noTreeForLongEnoughTurnsTheFlagsBackOnThroughTheShell() {
        let read = ["spawn", udid, "defaults", "read", AXSettings.domain]
        let write = [
            "spawn", udid, "defaults", "write", AXSettings.domain, "ApplicationAccessibilityEnabled", "-bool", "true",
        ]
        let shell = RecordingShell(replies: [read: defaultsRead(0, for: ["ApplicationAccessibilityEnabled"])])
        let clock = FakeClock()
        let s = Session(
            udid: udid, environment: .scripted(ax: ScriptedAX(frames: [nil]), shell: shell, clock: clock))
        // One `snapshot` with no tree spends 3000 fake ms: observe polls for 1500 ms, drops the connection, reconnects
        // and polls for another 1500 ms. The no-tree episode runs from the first failure, so heal sees 0 ms after the
        // first snapshot, 3000 after the second (under the 4000 ms patience) and 6000 after the third. Three it is.
        var out = s.run(["snapshot"])
        for _ in 0..<2 { out = s.run(["snapshot"]) }
        #expect(clock.now > AXHealth.patienceMs, "fake time \(clock.now)")
        let calls = shell.calls
        // (a) connect's write, then heal's forced one.
        #expect(calls.filter { $0 == write }.count >= 2, "\(calls)")
        // (b) a read after the first write can only be heal's diagnosis.
        let firstWrite = calls.firstIndex(of: write)
        #expect(firstWrite.map { calls[($0 + 1)...].contains(read) } == true, "\(calls)")
        // (c) the agent is told it is blind.
        #expect(out.exit != 0, "\(out.text)")
    }

    @Test func aPoisonedBridgeIsRestartedThroughTheShell() {
        let read = ["spawn", udid, "defaults", "read", AXSettings.domain]
        let shell = RecordingShell(replies: [read: defaultsRead(1, for: AXSettings.flags)])
        let clock = FakeClock()
        let s = Session(
            udid: udid, environment: .scripted(ax: ScriptedAX(frames: [nil]), shell: shell, clock: clock))
        // As above: three snapshots reach the patience. The restart's 1500 ms sleep and the extra 3000 ms poll happen
        // inside the third snapshot, after heal has decided, so they do not change the count.
        var out = s.run(["snapshot"])
        for _ in 0..<2 { out = s.run(["snapshot"]) }
        #expect(
            shell.calls.contains(["spawn", udid, "launchctl", "stop", "com.apple.CoreSimulator.bridge"]),
            "\(shell.calls)")
        #expect(out.exit != 0, "\(out.text)")
    }
}
