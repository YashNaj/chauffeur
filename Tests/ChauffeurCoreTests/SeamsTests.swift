import Foundation
import Testing

@testable import ChauffeurCore

@Suite @MainActor struct SeamsTests {
    @Test func aFakeDeviceReportsWhatItWasGiven() {
        let device: any SimDevice = FakeDevice(udid: "U-1", booted: true, size: Size(w: 402, h: 874))
        #expect(device.udid == "U-1")
        #expect(device.booted)
        #expect(device.size == Size(w: 402, h: 874))
    }

    @Test func scriptedTouchesReplayEvidenceAndHoldTheLast() {
        let touches = ScriptedTouches(evidence: [.none, .app("com.example"), .system], attached: true)
        #expect(touches.isAttached)
        #expect(touches.evidence(since: 0, waitMs: 0) == .none)
        #expect(touches.evidence(since: 0, waitMs: 0) == .app("com.example"))
        #expect(touches.evidence(since: 0, waitMs: 0) == .system)
        #expect(touches.evidence(since: 0, waitMs: 0) == .system)
    }

    @Test func scriptedTouchesAreNoneWhenEmptyAndUnavailableWhenDetached() {
        #expect(ScriptedTouches(evidence: [], attached: true).evidence(since: 0, waitMs: 0) == .none)
        let detached = ScriptedTouches(evidence: [.app("x")], attached: false)
        #expect(!detached.isAttached)
        #expect(detached.evidence(since: 0, waitMs: 0) == .unavailable)
    }

    @Test func scriptedTouchesAdvanceTheCursorOnlyForRecordedTouches() {
        let touches = ScriptedTouches(evidence: [.none, .app("x"), .system], attached: true)
        #expect(touches.cursor == 0)
        _ = touches.evidence(since: 0, waitMs: 0)
        #expect(touches.cursor == 0)
        _ = touches.evidence(since: 0, waitMs: 0)
        #expect(touches.cursor == 1)
        _ = touches.evidence(since: 1, waitMs: 0)
        #expect(touches.cursor == 2)
    }

    @Test func aRecordingShellRecordsCallsAndRepliesFromItsTable() throws {
        let read = ["spawn", "U-1", "defaults", "read", "k"]
        let shell = RecordingShell(replies: [read: ProcessResult(status: 1, out: "boom", timedOut: false)])
        let hit = try shell.simctl(read, stdin: nil, timeout: 5)
        #expect(hit.status == 1 && hit.out == "boom")
        let miss = try shell.simctl(["list"])
        #expect(miss.status == 0 && miss.out.isEmpty && !miss.timedOut)
        #expect(shell.calls == [read, ["list"]])
    }

    @Test func fakeProcessesAnswerLivenessFromTheirSet() {
        let table: any ProcessTable = FakeProcesses(alive: [10, 20])
        #expect(table.isAlive(10))
        #expect(!table.isAlive(30))
        #expect(table.parent(of: 10) == nil)
        #expect(table.children(of: 1, named: "x").isEmpty)
    }

    @Test func theProductionTypesConform() {
        let _: any ShellRunner = SimCtlRunner()
        let table: any ProcessTable = LiveProcessTable()
        #expect(table.isAlive(getpid()))
        let _: any TouchEvidenceSource = TouchLog(udid: "U", levelFile: URL(fileURLWithPath: "/dev/null"))
    }
}
