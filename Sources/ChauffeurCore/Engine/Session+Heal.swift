import Foundation

extension Session {
    /// Diagnoses a missing tree and applies the cure: flags back on, and a poisoned bridge restarted (at most once a minute).
    func heal(noTreeForMs: Int, ax: any AXSource, screen: Size) -> AXHealth.Plan {
        guard noTreeForMs >= AXHealth.patienceMs else {
            return AXHealth.Plan(enableFlags: [], restartBridge: false, relaunchApp: false)
        }
        let flagsOff =
            (try? shell.simctl(["spawn", udid, "defaults", "read", AXSettings.domain]).out).map(AXSettings.off) ?? []
        let probe = ax.probe(center: Point(x: screen.w / 2, y: screen.h / 2))
        let plan = AXHealth.plan(
            noTreeForMs: noTreeForMs, frontmostIsEmptyApp: probe.frontmostIsEmptyApp,
            screenAnswers: probe.screenAnswers, flagsOff: flagsOff,
            msSinceBridgeRestart: bridgeRestartedMs.map { clock.nowMs() - $0 })
        if !plan.enableFlags.isEmpty { _ = try? ensureAccessibility() }
        if plan.restartBridge { _ = restartBridge() }
        return plan
    }

    /// Restarts the simulator's accessibility bridge (launchd brings it back at once); returns the provider to read with.
    func restartBridge() -> (any AXSource)? {
        _ = try? shell.simctl(["spawn", udid, "launchctl", "stop", "com.apple.CoreSimulator.bridge"])
        bridgeRestartedMs = clock.nowMs()
        clock.sleep(ms: 1500)  // give it a moment to come up
        return ax
    }

    /// Turns on the accessibility flags an app needs at launch to serve its tree; returns the ones that were off.
    /// `force: false` checks at most every 60 s (the per-command path); launch always checks.
    func ensureAccessibility(force: Bool = true) throws -> [String] {
        if !force, let last = axCheckedMs, clock.nowMs() - last < 60_000 { return [] }
        axCheckedMs = clock.nowMs()
        return try AXSettings.ensure(udid: udid, shell: shell)
    }
}
