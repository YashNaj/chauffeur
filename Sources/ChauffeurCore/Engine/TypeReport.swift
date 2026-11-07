import Foundation

public enum TypeVerdict: Equatable, Sendable {
    case ok
    case mismatch(String)
    case fieldGone
}

/// Spec §6.6 and decision 5: verify typed text via the field's value; secure fields by bullet count.
public enum TypeCheck {
    public static func verify(typed: String, before: Node, after: Node?, submitted: Bool) -> TypeVerdict {
        guard let after else { return submitted ? .ok : .fieldGone }
        let old = before.value ?? ""
        let new = after.value ?? ""
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
    /// Requests the typing started by the time it was verified (M4b spec §2).
    public var requests: [RequestItem] = []
    public var requestElapsedMs = 0

    public init(action: String, method: String, verdict: TypeVerdict, value: String?, settledMs: Int) {
        self.action = action
        self.method = method
        self.verdict = verdict
        self.value = value
        self.settledMs = settledMs
    }

    public var exitCode: ExitCode { verdict == .ok ? .ok : .noEffect }

    public var json: JSON {
        var o: [String: JSON] = [
            "action": .string(action), "method": .string(method), "value": JSON(value),
            "settledMs": JSON(settledMs),
        ]
        switch verdict {
        case .ok:
            o["verdict"] = "ok"
        case .mismatch(let shown):
            o["verdict"] = "mismatch"
            o["shown"] = .string(shown)
        case .fieldGone:
            o["verdict"] = "fieldGone"
        }
        if !requests.isEmpty { o["requests"] = .array(requests.map(RequestText.json)) }
        return .object(o)
    }

    public func render() -> String {
        switch verdict {
        case .ok:
            return
                ([
                    "\(action) → typed via \(method) · value=\(Perception.quote(value ?? "")) · settled \(settledMs)ms"
                ] + RequestText.lines(requests, elapsedMs: requestElapsedMs)).joined(separator: "\n")
        case .mismatch(let shown):
            return "\(action) → TEXT MISMATCH via \(method) · field shows \(Perception.quote(shown))\n"
                + "hint: the field may limit or reformat input; run snapshot to see it"
        case .fieldGone:
            return "\(action) → FIELD GONE after typing · run snapshot"
        }
    }
}
