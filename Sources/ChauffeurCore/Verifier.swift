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
}

/// Spec §6.2: classify every action; never report success without a visible change.
public enum Verifier {
    /// What a NO EFFECT screenshot shows: the target's row widened to the screen, 120 pt above and below, on screen.
    public static func evidenceRegion(target: Rect, screen: Size) -> Rect {
        let y = max(0, target.y - 120), maxY = min(screen.h, target.maxY + 120)
        return Rect(x: 0, y: y, w: screen.w, h: maxY - y)
    }

    public static func classify(treeChanged: Bool, evidence: Evidence, expectedApp: String?,
                                systemFrontmost: Bool, retried: Bool, baselineSettled: Bool = true) -> Outcome {
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
            if !target.enabled { return ["\(ref) is disabled; fill in or select whatever it depends on first, then retry"] }
            return ["the app received the touch but its accessibility tree did not change; \(ref) may need a "
                    + "long press (--long 1), or the change is not exposed to accessibility (run snapshot)"]
        case .intercepted:
            return ["something else is on top of the app; run snapshot to see what"]
        case .notDelivered:
            return ["input transport unhealthy — run `chauffeur doctor --live`"]
        case .unverified:
            return ["touch log unavailable, so delivery is unknown; run `chauffeur doctor`"]
        case .unattributed:
            return ["wait for the screen to settle (chauffeur wait …), run snapshot, and check whether the action is still needed"]
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

    public init(action: String, outcome: Outcome, evidence: Evidence, settledMs: Int, settled: Bool, revBefore: Int,
                revAfter: Int, diff: [String], transport: String, retriedFrom: String?, hints: [String], capMs: Int) {
        self.action = action; self.outcome = outcome; self.evidence = evidence; self.settledMs = settledMs
        self.settled = settled; self.revBefore = revBefore; self.revAfter = revAfter; self.diff = diff
        self.transport = transport; self.retriedFrom = retriedFrom; self.hints = hints; self.capMs = capMs
    }

    public var exitCode: Int32 { outcome == .changed ? 0 : 3 }

    public func render() -> String {
        let cap = String(format: "%gs", Double(capMs) / 1000)
        var head: String
        switch outcome {
        case .changed:
            head = "\(action) → changed · " + (settled ? "settled \(settledMs)ms" : "still changing at \(cap)")
                + " · rev \(revBefore)→\(revAfter)"
            if let from = retriedFrom { head += " · via \(transport) after \(from) showed no touch" }
        case .noEffect:
            head = "\(action) → NO EFFECT · the accessibility tree did not change in \(cap) (touch reached \(owner))"
        case .intercepted(let by):
            head = "\(action) → INTERCEPTED by \(by) · nothing changed"
        case .notDelivered, .retry:
            head = "\(action) → NOT DELIVERED · " + (retriedFrom != nil ? "retried via \(transport) · " : "") + "still no touch"
        case .unverified:
            head = "\(action) → UNVERIFIED: no visible change (\(note ?? "touch log unavailable"))"
        case .unattributed:
            head = "\(action) → UNVERIFIED: the screen was already changing before the action, so the change can't be credited to it"
        }
        var tail = hints.map { "hint: " + $0 }
        if outcome == .noEffect, let shot = evidenceShot {
            tail.insert("screen: \(shot) (look before retrying: some changes, like checkmarks, never reach the tree)", at: 0)
        }
        return ([head] + diff + tail).joined(separator: "\n")
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

public enum TypeVerdict: Equatable, Sendable {
    case ok
    case mismatch(String)
    case fieldGone
}

/// Spec §6.6 and decision 5: verify typed text via the field's value; secure fields by bullet count.
public enum TypeCheck {
    public static func verify(typed: String, before: Node, after: Node?, submitted: Bool) -> TypeVerdict {
        guard let after else { return submitted ? .ok : .fieldGone }
        let old = before.value ?? "", new = after.value ?? ""
        if before.role == "securefield" {
            let added = new.filter { $0 == "•" }.count - old.filter { $0 == "•" }.count
            return added == typed.count ? .ok : .mismatch(new)
        }
        // The text must be new: more occurrences than before (a pre-filled "banana" doesn't prove "a" was typed).
        func count(_ s: String) -> Int { typed.isEmpty ? 0 : s.components(separatedBy: typed).count - 1 }
        return new != old && count(new) > count(old) ? .ok : .mismatch(new)
    }
}

public struct TypeReport: Sendable {
    public var action: String
    public var method: String
    public var verdict: TypeVerdict
    public var value: String?
    public var settledMs: Int

    public init(action: String, method: String, verdict: TypeVerdict, value: String?, settledMs: Int) {
        self.action = action; self.method = method; self.verdict = verdict; self.value = value; self.settledMs = settledMs
    }

    public var exitCode: Int32 { verdict == .ok ? 0 : 3 }

    public var json: JSON {
        var o: [String: JSON] = ["action": .string(action), "method": .string(method), "value": JSON(value),
                                 "settledMs": JSON(settledMs)]
        switch verdict {
        case .ok:
            o["verdict"] = "ok"
        case .mismatch(let shown):
            o["verdict"] = "mismatch"
            o["shown"] = .string(shown)
        case .fieldGone:
            o["verdict"] = "fieldGone"
        }
        return .object(o)
    }

    public func render() -> String {
        switch verdict {
        case .ok:
            return "\(action) → typed via \(method) · value=\(Perception.quote(value ?? "")) · settled \(settledMs)ms"
        case .mismatch(let shown):
            return "\(action) → TEXT MISMATCH via \(method) · field shows \(Perception.quote(shown))\n"
                + "hint: the field may limit or reformat input; run snapshot to see it"
        case .fieldGone:
            return "\(action) → FIELD GONE after typing · run snapshot"
        }
    }
}
