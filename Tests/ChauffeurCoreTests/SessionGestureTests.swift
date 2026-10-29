import Foundation
import Testing

@testable import ChauffeurCore

/// `scroll` and `swipe` offline (Task 12): both drag, and both are verified by the screen.
@Suite @MainActor struct SessionGestureTests {
    @Test func scrollReportsTheFoundLine() throws {
        // `fixture-longlist` has Row 1–14 only; the scroll lands on `long-scrollview`, scrolled so that "Label 69" is
        // on screen (`find` matches on-screen elements only). A static text gets no ref, so the line has none.
        // Baseline 4 reads of the list, then the act's observe sees the scroll view.
        let list = try Act.longlist()
        let rig = ActRig(frames: [list, list, list, list, try Act.longScrolled()])
        let out = rig.s.run(["scroll", "down", "--until", "Label 69"])
        #expect(out.exit == 0, "\(out.text)")
        #expect(out.text.hasPrefix("found text \"Label 69\" after "), "\(out.text)")
        #expect(rig.touches.requests.count == 1)
        #expect(out.text.hasSuffix("after 1 scroll down"), "\(out.text)")
    }

    @Test func swipeIsVerifiedByTheScreen() throws {
        let home = try Act.home()
        // Baseline 4 reads of home, then the act's observe sees the form.
        let rig = ActRig(frames: [home, home, home, home, try Act.form()])
        let out = rig.s.run(["swipe", "201,650", "201,250"])
        #expect(out.exit == 0 && out.text.hasPrefix("swipe (201,650)→(201,250) → changed"), "\(out.text)")
        #expect(rig.inputs.fakes[0].touches.map { $0.1 } == [.down] + Array(repeating: .move, count: 12) + [.up])
    }
}
