import Foundation

/// What the touch log says about a touch.
public enum Evidence: Equatable, Sendable {
    case none
    case app(String)
    case system
    case unavailable
}

public enum Outcome: Equatable, Sendable {
    case changed
    case noEffect
    case intercepted(String)
    case retry
    case notDelivered
    case unverified
    /// The screen was already changing before the action, so a change can't be credited to it.
    case unattributed
    /// The screen didn't change and the app is still waiting for a network reply (M4b spec §3): exit 6.
    case pending
}

/// Spec §6.2: classify every action; never report success without a visible change.
public enum Verifier {
    /// What a NO EFFECT screenshot shows: the target's row widened to the screen, 120 pt above and below, on screen.
    public static func evidenceRegion(target: Rect, screen: Size) -> Rect {
        let y = max(0, target.y - 120)
        let maxY = min(screen.h, target.maxY + 120)
        return Rect(x: 0, y: y, w: screen.w, h: maxY - y)
    }

    public static func classify(
        treeChanged: Bool, evidence: Evidence, expectedApp: String?,
        systemFrontmost: Bool, retried: Bool, baselineSettled: Bool = true
    ) -> Outcome {
        if treeChanged { return baselineSettled ? .changed : .unattributed }
        switch evidence {
        case .unavailable:
            return .unverified
        case .none:
            return retried ? .notDelivered : .retry
        case .system:
            return systemFrontmost ? .noEffect : .intercepted("system UI (SpringBoard)")
        case .app(let bundle):
            if !systemFrontmost, let expectedApp, bundle != expectedApp { return .intercepted(bundle) }
            return .noEffect
        }
    }

    public static func hints(outcome: Outcome, target: Node?) -> [String] {
        switch outcome {
        case .noEffect:
            guard let target else { return ["nothing at that point reacted; run snapshot and act on a ref"] }
            let ref = target.ref ?? "it"
            if !target.enabled {
                return ["\(ref) is disabled; fill in or select whatever it depends on first, then retry"]
            }
            return [
                "the app received the touch but its accessibility tree did not change; \(ref) may need a "
                    + "long press (--long 1), or the change is not exposed to accessibility (run snapshot)"
            ]
        case .intercepted:
            return ["something else is on top of the app; run snapshot to see what"]
        case .notDelivered:
            return ["input transport unhealthy — run `chauffeur doctor --live`"]
        case .unverified:
            return ["touch log unavailable, so delivery is unknown; run `chauffeur doctor`"]
        case .unattributed:
            return [
                "wait for the screen to settle (chauffeur wait …), run snapshot, and check whether the action is still needed"
            ]
        case .pending:
            return ["run `chauffeur wait` for the result"]
        case .changed, .retry:
            return []
        }
    }
}

/// The text an action prints (spec §5.4).
public struct ActionReport: Sendable {
    public var action: String
    public var outcome: Outcome
    public var evidence: Evidence
    public var settledMs: Int
    public var settled: Bool
    public var revBefore: Int
    public var revAfter: Int
    public var diff: [String]
    public var transport: String
    public var retriedFrom: String?
    public var hints: [String]
    public var capMs: Int
    /// Why an UNVERIFIED result could not be verified (default: the touch log was unavailable).
    public var note: String?
    /// A screenshot around the target, taken on NO EFFECT: the tree can miss a change the pixels show.
    public var evidenceShot: String?
    /// The requests and connections the action caused, telemetry included and marked (M4b spec §3).
    public var requests: [RequestItem] = []
    /// From the touch to the verdict: how long a missing reply has been waited for.
    public var requestElapsedMs = 0
    /// Characters the action copied to the clipboard (M4b spec §7).
    public var copiedCharacters: Int?
    /// Why the network couldn't be watched; shown with a NO EFFECT.
    public var networkNote: String?

    public init(
        action: String, outcome: Outcome, evidence: Evidence, settledMs: Int, settled: Bool, revBefore: Int,
        revAfter: Int, diff: [String], transport: String, retriedFrom: String?, hints: [String], capMs: Int
    ) {
        self.action = action
        self.outcome = outcome
        self.evidence = evidence
        self.settledMs = settledMs
        self.settled = settled
        self.revBefore = revBefore
        self.revAfter = revAfter
        self.diff = diff
        self.transport = transport
        self.retriedFrom = retriedFrom
        self.hints = hints
        self.capMs = capMs
    }

    public var exitCode: ExitCode {
        switch outcome {
        case .changed: return .ok
        case .pending: return .pending
        default: return .noEffect
        }
    }

    /// The request a NO EFFECT or PENDING headline names: the first missing reply, else the first failure, else the
    /// first request that isn't a stream, else the stream. Never telemetry.
    static func lead(_ requests: [RequestItem], pending: Bool) -> RequestItem? {
        let real = requests.filter { !$0.telemetry }
        if pending { return real.first(where: \.waiting) }
        return real.first(where: \.failed) ?? real.first(where: { !$0.streaming }) ?? real.first
    }

    public func render() -> String {
        let cap = String(format: "%gs", Double(capMs) / 1000)
        let lead = outcome == .changed ? nil : Self.lead(requests, pending: outcome == .pending)
        var head: String
        switch outcome {
        case .changed:
            if let copiedCharacters, diff.isEmpty {
                head = "\(action) → changed · copied to clipboard (\(copiedCharacters) characters)"
            } else {
                head =
                    "\(action) → changed · " + (settled ? "settled \(settledMs)ms" : "still changing at \(cap)")
                    + " · rev \(revBefore)→\(revAfter)"
                if let from = retriedFrom { head += " · via \(transport) after \(from) showed no touch" }
            }
        case .pending:
            head =
                "\(action) → PENDING · "
                + (lead.map { RequestText.outcome($0, elapsedMs: requestElapsedMs) } ?? "waiting for a reply")
        case .noEffect:
            if let lead {
                head =
                    "\(action) → NO EFFECT · " + RequestText.outcome(lead, elapsedMs: requestElapsedMs)
                    + (lead.failed || lead.streaming ? "" : ", but nothing changed on screen")
            } else {
                head =
                    "\(action) → NO EFFECT · the accessibility tree did not change in \(cap) (touch reached \(owner))"
            }
        case .intercepted(let by):
            head = "\(action) → INTERCEPTED by \(by) · nothing changed"
        case .notDelivered, .retry:
            head =
                "\(action) → NOT DELIVERED · " + (retriedFrom != nil ? "retried via \(transport) · " : "")
                + "still no touch"
        case .unverified:
            head = "\(action) → UNVERIFIED: no visible change (\(note ?? "touch log unavailable"))"
        case .unattributed:
            head =
                "\(action) → UNVERIFIED: the screen was already changing before the action, so the change can't be credited to it"
        }
        var requestLines: [String] = []
        if let lead {
            let more = RequestText.details(lead)
            if !more.isEmpty { requestLines.append("request: " + more) }
        }
        requestLines += RequestText.lines(requests, elapsedMs: requestElapsedMs, except: lead)
        var tail = hints.map { "hint: " + $0 }
        if outcome == .noEffect, let shot = evidenceShot {
            tail.insert(
                "screen: \(shot) (look before retrying: some changes, like checkmarks, never reach the tree)", at: 0)
        }
        if outcome == .noEffect, let networkNote { tail.append("note: network not watched (\(networkNote))") }
        return ([head] + diff + requestLines + tail).joined(separator: "\n")
    }

    /// The same report as data, for `--json` and MCP.
    public var json: JSON {
        var o: [String: JSON] = [
            "action": .string(action), "outcome": .string(outcomeName), "evidence": .string(evidenceName),
            "settled": .bool(settled), "settledMs": JSON(settledMs), "rev": [JSON(revBefore), JSON(revAfter)],
            "diff": JSON(diff), "transport": .string(transport), "hints": JSON(hints),
        ]
        if case .intercepted(let by) = outcome { o["interceptedBy"] = .string(by) }
        if let retriedFrom { o["retriedFrom"] = .string(retriedFrom) }
        if let note { o["note"] = .string(note) }
        if let evidenceShot { o["screenshot"] = .string(evidenceShot) }
        if !requests.isEmpty { o["requests"] = .array(requests.map(RequestText.json)) }
        if let copiedCharacters { o["copied"] = JSON(copiedCharacters) }
        return .object(o)
    }

    var outcomeName: String {
        switch outcome {
        case .changed: "changed"
        case .noEffect: "noEffect"
        case .intercepted: "intercepted"
        case .retry, .notDelivered: "notDelivered"
        case .unverified: "unverified"
        case .unattributed: "unattributed"
        case .pending: "pending"
        }
    }

    var evidenceName: String {
        switch evidence {
        case .none: "none"
        case .app(let bundle): "app:" + bundle
        case .system: "system"
        case .unavailable: "unavailable"
        }
    }

    private var owner: String {
        switch evidence {
        case .app(let bundle): return bundle
        case .system: return "system UI"
        case .none, .unavailable: return "the screen"
        }
    }
}

extension ActionReport {
    /// The one way a NO EFFECT becomes a change. `settledMs` and `settled` are passed, not computed: each site keeps
    /// its convention (the time since the touch, or the act's own settle, or the wait's observe). Sets outcome,
    /// revAfter, diff, settledMs, settled and hints; clears evidenceShot.
    mutating func credit(
        change after: Snapshot, from before: Snapshot, settledMs: Int, settled: Bool, hints: [String] = []
    ) {
        revAfter = after.rev
        diff = Diff.lines(from: before, to: after)
        self.settledMs = settledMs
        self.settled = settled
        crediting(hints: hints)
    }

    /// A copy is a change with nothing to show on screen: the revisions and the settle stay as the act left them.
    /// Sets outcome and copiedCharacters, empties hints; clears evidenceShot.
    mutating func credit(copied characters: Int) {
        copiedCharacters = characters
        crediting(hints: [])
    }

    private mutating func crediting(hints: [String]) {
        outcome = .changed
        self.hints = hints
        evidenceShot = nil
    }
}
