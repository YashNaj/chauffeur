import Foundation

extension Session {
    /// Runs `body`; when the app in front turns out to have been opened from its icon without accessibility, relaunches
    /// it through `launch` (which also follows its log) and runs `body` once more (M4b spec §8). Never inside a batch,
    /// at most once per app per session; otherwise today's message.
    func withRelaunch(_ body: () throws -> Output) throws -> Output {
        do {
            return try body()
        } catch ChauffeurError.needsRelaunch(let bundle, let why) {
            guard !inBatch, !relaunchedForAccessibility.contains(bundle) else { throw ChauffeurError.blind(why) }
            relaunchedForAccessibility.insert(bundle)
            let launched = relaunch?(bundle) ?? guarded { try launchCommand([bundle]) }
            guard launched.exit == 0 else { throw ChauffeurError.blind(why) }
            // A retry that fails still says the app was reset: the agent's next steps depend on it.
            var out = guarded(body)
            out.text +=
                "\nnote: relaunched \(bundle) — it was opened from its icon without accessibility; its in-app state "
                + "was reset"
            return out
        }
    }

    /// The bundle id of the empty app in front, from the pid the bridge reports for it: its root has no label to go by.
    func relaunchCandidate(_ ax: AXProvider) -> String? {
        guard let pid = ax.frontmostPID(), let list = try? SimCtl.run(["spawn", udid, "launchctl", "list"]).out else {
            return nil
        }
        return Self.relaunchBundle(frontPID: pid, launchctlList: list, launchedPID: app?.pid)
    }

    /// The app to relaunch: the running app with the front pid, unless chauffeur launched that very process itself,
    /// with accessibility on (its empty tree is then the app's own, and resetting it would be a guess).
    nonisolated static func relaunchBundle(frontPID: Int32?, launchctlList: String, launchedPID: Int32?) -> String? {
        guard let frontPID, frontPID != launchedPID else { return nil }
        return SimApps.runningApp(pid: frontPID, in: launchctlList)
    }
}
