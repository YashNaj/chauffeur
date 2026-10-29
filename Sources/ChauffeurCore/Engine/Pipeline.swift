import Foundation

/// What one action's classifier and passes may read. `act` builds it; a test builds one over a scripted session.
struct ActionContext {
    /// The report's `action`.
    var label: String
    var before: Snapshot
    var baselineSettled: Bool
    var target: Node?
    var capMs: Int
    /// `clock.nowMs()` right before the gesture (equal to `net?.touchMs`).
    var touchMs: Int
    var net: TapNet?
    /// `expectedApp(on: before)`: the launched app while it is in front.
    var expectedApp: String?
    /// `touchLog.isAttached`, read when asked: an observe that reconnects (`drop()`) stops the touch log, so it is
    /// read after the screen, as before.
    var isTouchLogAttached: () -> Bool
    var touchLogAttached: Bool { isTouchLogAttached() }
    var clock: any SettleClock
    var observe: (_ minMs: Int, _ capMs: Int) throws -> (snapshot: Snapshot, settle: Settled<AXElement>)
    /// `touchLog.evidence(since:waitMs: 200)`.
    var touchEvidence: (_ since: Int) -> Evidence
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
    func classify(context: ActionContext, attempt: Attempt) throws -> (report: ActionReport, after: Snapshot)
}

/// A touch: the screen after 150 ms or more, then the touch log's evidence since the send (spec §6.2).
struct TouchClassifier: Classifier {
    func classify(context: ActionContext, attempt: Attempt) throws -> (report: ActionReport, after: Snapshot) {
        let before = context.before
        let (after, settle) = try context.observe(150, context.capMs)
        let evidence: Evidence =
            !context.touchLogAttached
            ? .unavailable
            : attempt.sent ? context.touchEvidence(attempt.touchCursor) : .none
        let outcome = Verifier.classify(
            treeChanged: after.hash != before.hash, evidence: evidence, expectedApp: context.expectedApp,
            systemFrontmost: before.kind.isSystem, retried: attempt.retriedFrom != nil || attempt.isLast,
            baselineSettled: context.baselineSettled)
        let report = ActionReport(
            action: context.label, outcome: outcome, evidence: evidence, settledMs: settle.elapsedMs,
            settled: settle.settled, revBefore: before.rev, revAfter: after.rev,
            diff: outcome == .changed ? Diff.lines(from: before, to: after) : [],
            transport: attempt.transport, retriedFrom: attempt.retriedFrom,
            hints: Verifier.hints(outcome: outcome, target: context.target), capMs: context.capMs)
        return (report, after)
    }
}

/// An action with no touch evidence (a URL, a hardware button): a settled screen change is `changed`, a change on an
/// unsettled screen is unattributed, and no change is UNVERIFIED with `note` and `hints` (spec §6.2, last row).
struct NoTouchClassifier: Classifier {
    let note: String
    let hints: [String]

    func classify(context: ActionContext, attempt: Attempt) throws -> (report: ActionReport, after: Snapshot) {
        let before = context.before
        let capMs = context.capMs
        // The accessibility tree can lag the screen (SpringBoard after `button home` took over a second to show up), so
        // a tree that is merely stable is not "no change": keep looking until it differs or `capMs` has passed.
        let started = context.clock.nowMs()
        var (after, settle) = try context.observe(150, min(capMs, 600))
        while after.hash == before.hash, context.clock.nowMs() - started < capMs {
            (after, settle) = try context.observe(150, min(capMs, 600))
        }
        if after.hash != before.hash { (after, settle) = try context.observe(150, 1500) }
        let outcome: Outcome =
            after.hash == before.hash ? .unverified : context.baselineSettled ? .changed : .unattributed
        var report = ActionReport(
            action: context.label, outcome: outcome, evidence: .unavailable, settledMs: settle.elapsedMs,
            settled: settle.settled, revBefore: before.rev, revAfter: after.rev,
            diff: outcome == .changed ? Diff.lines(from: before, to: after) : [],
            transport: attempt.transport, retriedFrom: nil,
            hints: outcome == .unverified ? hints : Verifier.hints(outcome: outcome, target: nil), capMs: capMs)
        report.note = note
        return (report, after)
    }
}

@MainActor
protocol EvidencePass {
    /// Looks again, with whatever the pass watches, and may upgrade the report through `credit`. Never downgrades.
    func apply(to report: inout ActionReport, context: ActionContext, session: Session) throws
}
