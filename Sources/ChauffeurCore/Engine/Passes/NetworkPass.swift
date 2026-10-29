import Foundation

/// A tap's requests (M4b spec §3), only with `context.net`: a NO EFFECT may become PENDING, kept for a bare `wait`, or
/// carry the reply that explains it; a change gets its request lines. Other outcomes (delivery problems) are left
/// alone.
struct NetworkPass: EvidencePass {
    func apply(to report: inout ActionReport, context: ActionContext, session: Session) throws {
        guard let net = context.net, report.outcome == .noEffect || report.outcome == .changed else { return }
        if report.outcome == .noEffect, net.pids.isEmpty || session.flowSource == nil {
            report.networkNote = net.pids.isEmpty ? "no app process to watch" : "network statistics unavailable"
        }
        let clock = context.clock
        var previous: [FlowActivity] = []
        let verdict: NetVerdict
        if report.outcome == .changed {
            clock.sleep(ms: NetJudge.graceMs)
            verdict = RequestEvidence.verdict(session.netItems(net, previous: &previous))
        } else {
            let textField = context.target.map { Perception.textEntry.contains($0.role) } ?? false
            verdict = NetJudge.judge(
                clock: clock, touchMs: net.touchMs, extraWindowMs: textField ? NetJudge.textFieldWindowMs : 0
            ) {
                session.netItems(net, previous: &previous)
            }
        }
        report.requests = verdict.items
        report.requestElapsedMs = clock.nowMs() - net.touchMs
        guard report.outcome == .noEffect else { return }
        switch verdict {
        case .none:
            break
        case .pending:
            report.outcome = .pending
            report.hints = Verifier.hints(outcome: .pending, target: context.target)
            session.pendingTap = PendingTap(report: report, before: context.before, net: net, target: context.target)
        case .settled(let items):
            if let hint = ActionReport.lead(items, pending: false).flatMap(RequestText.hint) { report.hints = [hint] }
        }
    }
}
