/// What to do when no accessibility tree comes back (root causes in the M2 dogfood report, §3.1, and the M3a review).
public enum AXHealth {
    public struct Plan: Equatable, Sendable {
        public var enableFlags: [String]
        public var restartBridge: Bool
        /// The app in front started without its accessibility server; only a relaunch gives it a tree.
        public var relaunchApp: Bool
        public var isEmpty: Bool { enableFlags.isEmpty && !restartBridge && !relaunchApp }
    }

    /// Launches and transitions legitimately show no tree for a moment; heal only after this long.
    public static let patienceMs = 4000
    public static let restartEveryMs = 60_000
    /// Failures further apart than this are separate episodes: "no tree for 4 s" means 4 s of failures in a row.
    public static let episodeGapMs = 2000

    /// - frontmostIsEmptyApp: the bridge names an application in front but it has no children (no accessibility server,
    ///   as when it started while app accessibility was off).
    /// - screenAnswers: a hit-test at the screen's centre returns an element. A poisoned bridge still answers it while
    ///   frontmost returns nothing; an app that is still launching has nothing there yet.
    public static func plan(
        noTreeForMs: Int, frontmostIsEmptyApp: Bool, screenAnswers: Bool, flagsOff: [String],
        msSinceBridgeRestart: Int?
    ) -> Plan {
        guard noTreeForMs >= patienceMs else { return Plan(enableFlags: [], restartBridge: false, relaunchApp: false) }
        let relaunch = frontmostIsEmptyApp || !flagsOff.isEmpty
        let restart = !relaunch && screenAnswers && (msSinceBridgeRestart.map { $0 >= restartEveryMs } ?? true)
        return Plan(enableFlags: flagsOff, restartBridge: restart, relaunchApp: relaunch)
    }

    /// When the current no-tree episode started, given this failure at `nowMs` of an attempt that began at
    /// `attemptStartedMs`.
    public static func episodeStart(current: Int?, lastFailureMs: Int?, attemptStartedMs: Int, nowMs: Int) -> Int {
        guard let current, let lastFailureMs, attemptStartedMs - lastFailureMs <= episodeGapMs else { return nowMs }
        return current
    }

    public static func message(_ plan: Plan, recovered: Bool) -> String {
        if plan.restartBridge {
            return recovered
                ? "the simulator's accessibility bridge had stopped answering; chauffeur restarted it"
                : "no accessibility tree even after restarting the simulator's accessibility bridge. Run: chauffeur doctor"
        }
        if plan.relaunchApp {
            let flags =
                plan.enableFlags.isEmpty
                ? ""
                : " App accessibility was off (\(plan.enableFlags.joined(separator: ", ")), as an Xcode device session leaves it); chauffeur turned it back on."
            return "the app in front shows no accessibility tree. If it has finished launching, it started while app "
                + "accessibility was off." + flags + " relaunch it: chauffeur launch <bundle>"
        }
        return
            "no accessibility tree yet (app still launching, or nothing in the foreground). Retry, or run: chauffeur doctor"
    }
}
