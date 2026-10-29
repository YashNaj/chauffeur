import Foundation

/// The picture a NO EFFECT carries: the region around its target, so the agent can see what did not change.
@MainActor
enum EvidenceShot {
    /// After every pass, only when `report.outcome == .noEffect` and the target has a frame. A screenshot that fails
    /// leaves the report without one.
    static func capture(_ report: inout ActionReport, context: ActionContext, session: Session) {
        guard report.outcome == .noEffect, let frame = context.target?.frame else { return }
        let screen = context.before.size
        if let shot = try? session.capture(
            screen: screen, zoom: Verifier.evidenceRegion(target: frame, screen: screen))
        {
            report.evidenceShot = shot.path
        }
    }
}
