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
            var out = try body()
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
        return SimApps.runningApp(pid: pid, in: list)
    }
}
