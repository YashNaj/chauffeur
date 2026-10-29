import Foundation
import Testing

@testable import ChauffeurCore

extension Live {
    /// Timing runs only when asked for as well as the UDID: `scripts/live-timing.sh <udid>` runs it on two trees.
    static var timing: Bool { udid != nil && ProcessInfo.processInfo.environment["CHAUFFEUR_LIVE_TIMING"] != nil }
}

/// Medians of 7 rounds of plain taps (Show alert, then OK; both change the screen, so 14 taps), 7 dead taps (the Form
/// tab's disabled Submit: NO EFFECT with its screenshot, no server needed) and 5 types into the Form's email field,
/// printed as one line `timing: tap <ms> dead <ms> type <ms>` for scripts/live-timing.sh. Every action's exit code is
/// asserted. Self-contained (it uses only what `main` already has) so the script can copy it into a base worktree.
@Suite(.enabled(if: Live.timing), .serialized)
@MainActor struct TimingLiveTests {
    @Test func medians() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)

        /// Wall-clock milliseconds of one command; the exit code is checked here so no sample is silently wrong.
        func timed(_ args: [String], exit expected: Int32) -> Double {
            let start = Date()
            let out = s.run(args)
            let ms = Date().timeIntervalSince(start) * 1000
            #expect(out.exit == expected, "\(args) exited \(out.exit): \(out.text)")
            return ms
        }
        func median(_ xs: [Double]) -> Int {
            let sorted = xs.sorted()
            return Int((sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2)
        }

        var taps: [Double] = []
        for _ in 0..<7 {
            taps.append(timed(["tap", try ref(s, "Show alert")], exit: 0))
            taps.append(timed(["tap", try ref(s, "button:OK")], exit: 0))
        }

        #expect(s.run(["tap", try ref(s, "tab:Form")]).exit == 0)
        var dead: [Double] = []
        for _ in 0..<7 { dead.append(timed(["tap", try ref(s, "button:Submit")], exit: 3)) }

        var types: [Double] = []
        for _ in 0..<5 { types.append(timed(["type", try ref(s, "textfield:email"), "x"], exit: 0)) }

        print("timing: tap \(median(taps)) dead \(median(dead)) type \(median(types))")
    }
}
