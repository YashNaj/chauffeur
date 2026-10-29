import Foundation

/// Right after typing, a switch can ignore the first touch that reaches the app (F1, M2 dogfood; reproduced in M3a
/// Task 7, no keyboard or overlay on screen). Its value is in the tree and did not change, so one more touch cannot
/// toggle it twice unnoticed. Listed only for a plain tap (`holdMs == 50`).
struct SwitchRetryPass: EvidencePass {
    func apply(to report: inout ActionReport, context: ActionContext, session: Session) throws {
        guard report.outcome == .noEffect, context.target?.role == "switch", let gesture = context.gesture else {
            return
        }
        let (again, settledAgain) = try session.baseline()
        if again.hash != context.before.hash {
            // The first touch did work, only later than 1.5 s: never toggle it back. The act's own settle stays
            // (convention 2).
            report.credit(
                change: again, from: context.before, settledMs: report.settledMs, settled: report.settled,
                hints: ["the switch changed only after 1.5s"])
            return
        }
        let network = session.network.start(appPid: session.app?.pid) { session.ax?.frontmostPID() }
        // `shot: false`: the outer act takes the one shot, after every pass.
        report = try session.act(
            report.action, target: context.target, before: again, baselineSettled: settledAgain,
            network: network, passes: [NetworkPass(), ScreenAgainPass()], shot: false, gesture: gesture)
        if report.outcome == .changed {
            report.hints.append("the first touch reached the app but the switch ignored it; chauffeur tapped once more")
        }
    }
}
