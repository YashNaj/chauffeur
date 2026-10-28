import Foundation
import Testing

@testable import ChauffeurCore

/// `observe`, `baseline` and `wait` offline: regression pins for the revision counter, the wait loop and the quiet
/// wait, all driven by `ScriptedAX` frames and a `FakeClock`.
///
/// How many frames a read costs: `snapshot` is `observe(minMs: 0, capMs: 1500)`, and `Settle.wait` settles once two
/// consecutive reads hash the same. A stable screen costs 2 reads (and 75 fake ms); a change in the middle of a read
/// costs one more, because the second read differs from the first and a third must agree with it. `connect()` reads
/// nothing from the tree, so every frame below is spent by `observe` alone.
@Suite @MainActor struct SessionObserveTests {
    private let udid = "ZZ000000-TEST"

    @Test func revBumpsOnlyWhenTheSnapshotChanges() throws {
        let home = try Fixtures.ax("fixture-home")
        let form = try Fixtures.ax("fixture-form")
        // Reads per snapshot: #1 takes frames 0,1 (home, home) and settles on home: rev 1.
        // #2 takes frames 2,3 (home, home), the same hash, so rev stays 1.
        // #3 takes frames 4,5 (form, form) and settles on form: rev 2.
        let s = Session(
            udid: udid,
            environment: .scripted(ax: ScriptedAX(frames: [home, home, home, home, form, form])))
        #expect(s.run(["snapshot"]).text.contains("rev 1"))
        #expect(s.run(["snapshot"]).text.contains("rev 1"))
        #expect(s.run(["snapshot"]).text.contains("rev 2"))
    }

    @Test func waitFindsTextOnALaterFrame() throws {
        let home = try Fixtures.ax("fixture-home")
        let form = try Fixtures.ax("fixture-form")
        let clock = FakeClock()
        // Reads per wait iteration (observe, capMs 500): iteration 1 takes frames 0,1 (home, home), iteration 2 takes
        // 2,3 (home, home), iteration 3 takes 4,5 (form, form) and finds the label that only the form has.
        let s = Session(
            udid: udid,
            environment: .scripted(
                ax: ScriptedAX(frames: [home, home, home, home, form, form]), clock: clock))
        let out = s.run(["wait", "Agree to terms", "--timeout", "5"])
        #expect(out.exit == 0 && out.text.hasPrefix("found after "), "\(out.text)")
        // Two misses before the hit: each cost 75 ms of reads and the loop's 100 ms sleep.
        #expect(clock.now >= 2 * (75 + 100), "fake time \(clock.now)")
    }

    @Test func waitTimeoutAbove300IsClampedNotRefused() throws {
        let home = try Fixtures.ax("fixture-home")
        let clock = FakeClock()
        let s = Session(
            udid: udid, environment: .scripted(ax: ScriptedAX(frames: [home]), clock: clock))
        // Each iteration reads 2 frames of the held screen (75 ms) and sleeps 100 ms, until 300 s have passed.
        let out = s.run(["wait", "Nowhere", "--timeout", "600"])
        #expect(out.exit == 4 && out.text.contains("after 300s"), "\(out.text)")
        #expect(clock.now >= 300_000, "fake time \(clock.now)")
    }

    @Test func baselineWaitsForTheScreenToBeQuiet() throws {
        let home = try Fixtures.ax("fixture-home")
        let clock = FakeClock()
        let s = Session(
            udid: udid, environment: .scripted(ax: ScriptedAX(frames: [home]), clock: clock))

        // The first sight of the screen is a change, which sets `lastChangeMs` to the end of the first observe (75 ms
        // of reads). The screen has been quiet for 0 ms, so baseline sleeps 500 ms and observes again (75 ms more).
        // The second observe sees the same hash, so no change and no more waiting: 75 + 500 + 75 fake ms.
        var started = clock.now
        let first = try s.baseline()
        let waited = clock.now - started
        #expect(waited >= 500 + 75, "a fresh change waited only \(waited) ms")
        #expect(first.snapshot.rev == 1 && first.settled)
        #expect(s.lastChangeMs == 75, "lastChangeMs \(s.lastChangeMs)")

        // The screen has now been quiet for 575 ms, so baseline takes one observe and returns without sleeping.
        started = clock.now
        let second = try s.baseline()
        #expect(clock.now - started == 75, "a quiet screen waited \(clock.now - started) ms")
        #expect(second.snapshot.rev == 1 && second.settled)
    }
}
