import Foundation

/// Typing's requests: one look after the grace, no window. Typing is verified by the field, so a late request can't
/// make it a false NO EFFECT. Not an `EvidencePass`: `type` has no `ActionContext`, and its report is a `TypeReport`.
@MainActor
struct TypingNetworkPass {
    func apply<C: EvidenceCarrier>(to carrier: inout C, net: TapNet, session: Session) {
        carrier.requests = session.network.sampleOnce(net)
        carrier.requestElapsedMs = session.clock.nowMs() - net.touchMs
    }
}
