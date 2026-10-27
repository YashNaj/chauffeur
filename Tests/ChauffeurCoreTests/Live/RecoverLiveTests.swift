import Foundation
import Testing

@testable import ChauffeurCore

/// M4b spec §8: an app opened without accessibility is relaunched once, with a note (Plan 1, Task 5; checked by hand
/// then, pinned here).
@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct RecoverLiveTests {
    @Test func anIconLaunchedAppIsRelaunched() throws {
        let udid = Live.udid!
        _ = try Live.buildFixture()
        let flag = [
            "spawn", udid, "defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled",
            "-bool",
        ]
        try SimCtl.run(flag + ["false"])
        try SimCtl.run(["terminate", udid, Live.fixture])
        try SimCtl.run(["launch", udid, Live.fixture], timeout: 60)
        sleep(4)
        try SimCtl.run(flag + ["true"])
        let s = Session(udid: udid)
        defer { s.shutdown() }
        var out = s.run(["snapshot"])
        for _ in 0..<3 where out.exit != 0 { out = s.run(["snapshot"]) }
        #expect(out.exit == 0, "\(out.text)")
        #expect(out.text.contains("note: relaunched dev.chauffeur.fixture"), "\(out.text)")
    }
}
