import Foundation

/// What one action's classifier and passes may read: plain data, built by `act`.
struct ActionContext {
    var label: String
    var before: Snapshot
    var baselineSettled: Bool
    var target: Node?
    var capMs: Int
    var net: TapNet?
    var expectedApp: String?
    /// The gesture, for a pass that sends it once more; nil for an action without a touch.
    var gesture: ((any TouchTransport) -> Bool)?
}

/// One send: what `act` knows after the gesture and before the screen is read.
struct Attempt {
    var sent: Bool
    var touchCursor: Int
    /// "none" without a touch.
    var transport: String
    var retriedFrom: String?
    /// No transport is left after this one, so `.retry` is classified as `retried` (NOT DELIVERED) here, not by `act`.
    var isLast: Bool

    static let noTouch = Attempt(sent: true, touchCursor: 0, transport: "none", retriedFrom: nil, isLast: true)
}

@MainActor
protocol Classifier {
    /// Observes, reads the evidence and classifies the action.
    func classify(context: ActionContext, attempt: Attempt, session: Session) throws -> ActionReport
}

/// A touch: the screen after 150 ms or more, then the touch log's evidence since the send (spec §6.2).
struct TouchClassifier: Classifier {
    func classify(context: ActionContext, attempt: Attempt, session: Session) throws -> ActionReport {
        let (after, settle) = try session.observe(minMs: 150, capMs: context.capMs)
        // Read after the screen: an observe that reconnects (`drop()`) stops the touch log.
        let evidence: Evidence =
            !session.touchLog.isAttached
            ? .unavailable
            : attempt.sent ? session.touchLog.evidence(since: attempt.touchCursor, waitMs: 200) : .none
        let outcome = Verifier.classify(
            treeChanged: after.hash != context.before.hash, evidence: evidence, expectedApp: context.expectedApp,
            systemFrontmost: context.before.kind.isSystem, retried: attempt.retriedFrom != nil || attempt.isLast,
            baselineSettled: context.baselineSettled)
        return ActionReport(
            action: context.label, outcome: outcome, evidence: evidence, settledMs: settle.elapsedMs,
            settled: settle.settled, revBefore: context.before.rev, revAfter: after.rev,
            diff: outcome == .changed ? Diff.lines(from: context.before, to: after) : [],
            transport: attempt.transport, retriedFrom: attempt.retriedFrom,
            hints: Verifier.hints(outcome: outcome, target: context.target), capMs: context.capMs)
    }
}

/// An action with no touch evidence (a URL, a hardware button): a settled screen change is `changed`, a change on an
/// unsettled screen is unattributed, and no change is UNVERIFIED with `note` and `hints` (spec §6.2, last row).
struct NoTouchClassifier: Classifier {
    let note: String
    let hints: [String]

    func classify(context: ActionContext, attempt: Attempt, session: Session) throws -> ActionReport {
        // The accessibility tree can lag the screen (SpringBoard after `button home` took over a second to show up), so
        // a tree that is merely stable is not "no change": keep looking until it differs or `capMs` has passed.
        let started = session.clock.nowMs()
        var (after, settle) = try session.observe(minMs: 150, capMs: min(context.capMs, 600))
        while after.hash == context.before.hash, session.clock.nowMs() - started < context.capMs {
            (after, settle) = try session.observe(minMs: 150, capMs: min(context.capMs, 600))
        }
        if after.hash != context.before.hash { (after, settle) = try session.observe(minMs: 150, capMs: 1500) }
        let outcome: Outcome =
            after.hash == context.before.hash ? .unverified : context.baselineSettled ? .changed : .unattributed
        var report = ActionReport(
            action: context.label, outcome: outcome, evidence: .unavailable, settledMs: settle.elapsedMs,
            settled: settle.settled, revBefore: context.before.rev, revAfter: after.rev,
            diff: outcome == .changed ? Diff.lines(from: context.before, to: after) : [],
            transport: attempt.transport, retriedFrom: nil,
            hints: outcome == .unverified ? hints : Verifier.hints(outcome: outcome, target: nil), capMs: context.capMs)
        report.note = note
        return report
    }
}

@MainActor
protocol EvidencePass {
    /// Looks again, with whatever the pass watches, and may upgrade the report through `credit`. Never downgrades.
    func apply(to report: inout ActionReport, context: ActionContext, session: Session) throws
}
