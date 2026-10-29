import Foundation

/// A copy changes nothing on screen; the pasteboard is read again only after a NO EFFECT (spec §7: a read costs
/// ~100 ms). `before` is the mark `tapCommand` took before the action.
struct ClipboardPass: EvidencePass {
    let before: ClipboardMark?

    func apply(to report: inout ActionReport, context: ActionContext, session: Session) throws {
        guard report.outcome == .noEffect,
            let copied = ClipboardMark.copied(
                before: before, after: Session.readClipboard(udid: session.udid, shell: session.shell))
        else { return }
        report.credit(copied: copied)
    }
}
