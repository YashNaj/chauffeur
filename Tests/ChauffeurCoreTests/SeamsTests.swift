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

    @Test func aRecordingShellThrowsOnATimedOutReplyAfterRecordingTheCall() {
        let args = ["spawn", "U-1", "log", "show"]
        let shell = RecordingShell(replies: [args: ProcessResult(status: 0, out: "", timedOut: true)])
        #expect(throws: ChauffeurError.simulatorServiceUnresponsive(command: "simctl spawn U-1")) {
            try shell.simctl(args, stdin: nil, timeout: 5)
        }
        #expect(shell.calls == [args])
    }

    @Test func scriptedTouchesRecordTheCursorAndWaitOfEveryRequest() {
        let touches = ScriptedTouches(evidence: [.none], attached: true)
        _ = touches.evidence(since: 3, waitMs: 250)
        _ = touches.evidence(since: 4, waitMs: 0)
        #expect(touches.requests.map(\.since) == [3, 4])
        #expect(touches.requests.map(\.waitMs) == [250, 0])
        let detached = ScriptedTouches(evidence: [], attached: false)
        _ = detached.evidence(since: 7, waitMs: 1)
        #expect(detached.requests.map(\.since) == [7])
    }

    @Test func fakeProcessesAnswerLivenessFromTheirSet() {
        let table: any ProcessTable = FakeProcesses(alive: [10, 20])
        #expect(table.isAlive(10))
        #expect(!table.isAlive(30))
        #expect(table.parent(of: 10) == nil)
        #expect(table.children(of: 1, named: "x").isEmpty)
    }

    @Test func recordingShellRecordsStdinAndTimeoutAndRepliesInOrder() throws {
        let args = ["spawn", "U", "pbpaste"]
        let shell = RecordingShell(replies: [
            args: [
                ProcessResult(status: 0, out: "before", timedOut: false),
                ProcessResult(status: 0, out: "after", timedOut: false),
            ]
        ])
        #expect(try shell.simctl(args, stdin: nil, timeout: 5).out == "before")
        #expect(try shell.simctl(args, stdin: "x", timeout: 15).out == "after")
        #expect(try shell.simctl(args, stdin: nil, timeout: 5).out == "after")  // the last reply holds
        #expect(shell.calls == [args, args, args])
        #expect(shell.recorded.map(\.stdin) == [nil, "x", nil] && shell.recorded.map(\.timeout) == [5, 15, 5])
    }

    @Test func fakeProcessesChangeBetweenCommands() {
        let procs = FakeProcesses(alive: [1])
        let table: any ProcessTable = procs
        #expect(table.isAlive(1))
        procs.alive = []
        #expect(!table.isAlive(1))
    }

    @Test func theProductionTypesConform() {
        let _: any ShellRunner = SimCtlRunner()
        let table: any ProcessTable = LiveProcessTable()
        #expect(table.isAlive(getpid()))
        let _: any TouchEvidenceSource = TouchLog(udid: "U", levelFile: URL(fileURLWithPath: "/dev/null"))
    }
}
