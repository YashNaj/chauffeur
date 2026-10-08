import Foundation

public enum RefError: Error, Equatable, CustomStringConvertible {
    case unknown(String)
    case stale(String, name: String?)
    case offScreen(String, name: String?)

    public var description: String {
        switch self {
        case .unknown(let ref):
            return "unknown ref \(ref) — run snapshot to get current refs"
        case .stale(let ref, let name):
            return "stale ref \(ref)\(name.map { " (\(Perception.quote($0)))" } ?? "") — not on screen; run snapshot"
        case .offScreen(let ref, let name):
            return "\(ref)\(name.map { " (\(Perception.quote($0)))" } ?? "") is off screen — scroll to it first"
        }
    }
}

extension Snapshot {
    /// `"text"` or `"role:text"`; case-insensitive on name, value and identifier; on-screen nodes only.
    public func find(_ query: String) -> [Node] {
        var role: String?
        var text = query
        if let colon = query.firstIndex(of: ":") {
            let prefix = String(query[..<colon]).lowercased()
            if !prefix.isEmpty, prefix.allSatisfy(\.isLetter) {
                role = prefix
                text = String(query[query.index(after: colon)...])
            }
        }
        return nodes.filter { n in
            guard onScreen(n), role == nil || n.role == role else { return false }
            if text.isEmpty { return true }
            return [n.name, n.value, n.identifier].contains { $0?.localizedCaseInsensitiveContains(text) == true }
        }
    }

    public func node(identity: Identity) -> Node? {
        nodes.first { $0.identity == identity }
    }

    public func resolve(ref: String, refs: RefTable) throws(RefError) -> Node {
        guard let identity = refs.identity(for: ref) else { throw .unknown(ref) }
        let name = refs.name(for: ref) ?? (identity.key.isEmpty ? nil : identity.key)
        guard let node = node(identity: identity) else { throw .stale(ref, name: name) }
        guard onScreen(node) else { throw .offScreen(ref, name: node.name) }
        return node
    }
}

/// Line diff between two snapshots' bodies (spec §5.4).
public enum Diff {
    public static func lines(from old: Snapshot, to new: Snapshot, limit: Int = 12) -> [String] {
        let a = old.bodyLines(all: false)
        let b = new.bodyLines(all: false)
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] > lcs[i + 1][j] {
                out.append("+ " + b[j])
                j += 1
            } else {
                out.append("- " + a[i])
                i += 1
            }
        }
        guard out.count > limit else { return out }
        // Cut: what appeared matters more than what went away, so additions go first.
        let ordered = out.filter { $0.hasPrefix("+") } + out.filter { !$0.hasPrefix("+") }
        return Array(ordered.prefix(limit)) + ["… \(out.count - limit) more changes — run snapshot"]
    }
}
