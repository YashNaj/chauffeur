import Foundation

/// What a ref is bound to: role, identifier-or-name, nearest named ancestor, ordinal among equals.
public struct Identity: Hashable, Sendable {
    public var role: String
    public var key: String
    public var ancestor: String?
    public var ordinal: Int

    public init(role: String, key: String, ancestor: String?, ordinal: Int) {
        self.role = role
        self.key = key
        self.ancestor = ancestor
        self.ordinal = ordinal
    }
}

/// One line of a snapshot.
public struct Node: Equatable, Sendable {
    public var role: String
    public var name: String?
    public var value: String?
    public var identifier: String?
    public var enabled: Bool
    public var frame: Rect
    public var depth: Int
    public var identity: Identity
    public var ref: String?
}

public struct Offscreen: Equatable, Hashable, Sendable {
    public var above = 0, below = 0, left = 0, right = 0
    public init() {}
}

public enum ScreenKind: Equatable, Sendable {
    case app(String)
    case springboard
    case systemAlert(over: String)

    public var isSystem: Bool {
        if case .app = self { return false }
        return true
    }
}

public struct Snapshot: Sendable {
    public var kind: ScreenKind
    public var title: String?
    public var size: Size
    public var orientation: Orientation
    public var rev: Int
    public var nodes: [Node]
    public var offscreen: Offscreen
    /// Changes when anything an agent could see changes (role, name, value, enabled, frame, offscreen counts).
    public var hash: Int

    public var header: String {
        let tail = "\(Geometry.fmt(size.w))×\(Geometry.fmt(size.h))pt \(orientation.rawValue) · rev \(rev)"
        switch kind {
        case .app(let name):
            return "app \(Perception.quote(name))" + (title.map { " · screen \(Perception.quote($0))" } ?? "") + " · "
                + tail
        case .springboard:
            return "SpringBoard · " + tail
        case .systemAlert(let over):
            return "system alert over \(Perception.quote(over)) · " + tail
        }
    }

    public func line(_ n: Node, all: Bool) -> String {
        var parts = [n.role]
        if let name = n.name { parts.append(Perception.quote(name)) }
        if let ref = n.ref { parts.append("[\(ref)]") }
        if let v = n.value {
            parts.append(
                ["switch", "checkbox", "tab", "radio"].contains(n.role) ? "value=\(v)" : "value=\(Perception.quote(v))")
        }
        if !n.enabled { parts.append("disabled") }
        if all {
            let f = n.frame
            parts.append("@\(Geometry.fmt(f.x)),\(Geometry.fmt(f.y)),\(Geometry.fmt(f.w)),\(Geometry.fmt(f.h))")
        }
        return String(repeating: "  ", count: n.depth) + parts.joined(separator: " ")
    }

    public func bodyLines(all: Bool) -> [String] {
        var lines = nodes.map { line($0, all: all) }
        if offscreen.above > 0 { lines.append("↑ \(offscreen.above) more above — scroll up") }
        if offscreen.below > 0 { lines.append("↓ \(offscreen.below) more below — scroll down") }
        if offscreen.left > 0 { lines.append("← \(offscreen.left) more left — scroll left") }
        if offscreen.right > 0 { lines.append("→ \(offscreen.right) more right — scroll right") }
        return lines
    }

    public func render(all: Bool = false) -> String {
        ([header] + bodyLines(all: all)).joined(separator: "\n")
    }

    public func onScreen(_ node: Node) -> Bool {
        node.frame.intersects(Rect(x: 0, y: 0, w: size.w, h: size.h))
    }

    /// The snapshot as data for `--json`: the same elements as the text; `all` adds frames as `--all` does.
    public func json(all: Bool) -> JSON {
        var o: [String: JSON] = [
            "size": [JSON(size.w), JSON(size.h)], "orientation": .string(orientation.rawValue), "rev": JSON(rev),
            "nodes": .array(nodes.map { $0.json(all: all) }),
            "offscreen": [
                "above": JSON(offscreen.above), "below": JSON(offscreen.below),
                "left": JSON(offscreen.left), "right": JSON(offscreen.right),
            ],
        ]
        switch kind {
        case .app(let name):
            o["kind"] = "app"
            o["app"] = .string(name)
        case .springboard:
            o["kind"] = "springboard"
        case .systemAlert(let over):
            o["kind"] = "systemAlert"
            o["over"] = .string(over)
        }
        if let title { o["screen"] = .string(title) }
        return .object(o)
    }
}

extension Node {
    /// One element as data; `all` adds its frame in points.
    public func json(all: Bool) -> JSON {
        var o: [String: JSON] = ["role": .string(role), "depth": JSON(depth), "enabled": .bool(enabled)]
        if let name { o["name"] = .string(name) }
        if let value { o["value"] = .string(value) }
        if let ref { o["ref"] = .string(ref) }
        if let identifier { o["id"] = .string(identifier) }
        if all { o["frame"] = [JSON(frame.x), JSON(frame.y), JSON(frame.w), JSON(frame.h)] }
        return .object(o)
    }
}
