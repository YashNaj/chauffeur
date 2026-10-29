import Foundation

/// Spec §3: a reply that is not telemetry arrived inside the request window, so the screen is judged again as it is
/// now. Without this, a response the app draws after its reply would be a false NO EFFECT. A change is credited with
/// the time since the touch (convention 1).
struct ScreenAgainPass: EvidencePass {
    func apply(to report: inout ActionReport, context: ActionContext, session: Session) throws {
        guard let net = context.net, report.outcome == .noEffect, report.requests.contains(where: { !$0.telemetry })
        else { return }
        let (again, settle) = try session.observe(minMs: 150, capMs: context.capMs)
        guard again.hash != context.before.hash else { return }
        report.credit(
            change: again, from: context.before, settledMs: session.clock.nowMs() - net.touchMs,
            settled: settle.settled)
    }
}
