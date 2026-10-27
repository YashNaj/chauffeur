import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec §7: only a length leaves the daemon.
@Suite struct ClipboardTests {
    @Test func aNewNonEmptyValueIsACopy() {
        let before = ClipboardMark("old")
        #expect(ClipboardMark.copied(before: before, after: ClipboardMark("FIXTURE-CODE-2026")) == 17)
        #expect(ClipboardMark.copied(before: before, after: ClipboardMark("old")) == nil)
        #expect(ClipboardMark.copied(before: before, after: ClipboardMark("")) == nil)
        #expect(ClipboardMark.copied(before: nil, after: ClipboardMark("x")) == nil)  // no before: can't tell
    }

    @Test func aMarkKeepsNoText() {
        let mark = String(describing: ClipboardMark("hunter2"))
        #expect(!mark.contains("hunter2"))
    }

    @Test func backgroundWorkIsCollected() {
        let quick = Background { 42 }
        #expect(quick.result(waitingAtMost: 1000) == 42)
        #expect(quick.result(waitingAtMost: 0) == 42)  // a second read gets the same value
        let slow = Background { () -> Int in
            usleep(300_000)
            return 1
        }
        #expect(slow.result(waitingAtMost: 10) == nil)
    }
}
