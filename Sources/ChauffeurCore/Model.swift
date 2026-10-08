import Foundation

public enum Chauffeur {
    public static let version = "0.1.1"

    /// Version plus the executable's build stamp: a rebuilt CLI must replace a daemon from an older build (I6).
    public static let buildID: String = {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        return build(stamp: Int(modified?.timeIntervalSince1970 ?? 0))
    }()

    static func build(stamp: Int) -> String { "\(version)+\(stamp)" }
}

public struct Point: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Size: Equatable, Hashable, Sendable {
    public var w: Double
    public var h: Double
    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

/// A frame in points. Encodes as `[x, y, w, h]`, the format of the M0 fixtures.
public struct Rect: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var center: Point { Point(x: x + w / 2, y: y + h / 2) }
    public var isEmpty: Bool { w <= 0 || h <= 0 }

    public func contains(_ p: Point) -> Bool { p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY }
    public func intersects(_ r: Rect) -> Bool { x < r.maxX && r.x < maxX && y < r.maxY && r.y < maxY }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(
            x: try c.decode(Double.self), y: try c.decode(Double.self),
            w: try c.decode(Double.self), h: try c.decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
        try c.encode(w)
        try c.encode(h)
    }
}

/// One raw accessibility element as AXProvider reads it: no pruning, no refs.
public struct AXElement: Codable, Hashable, Sendable {
    public var role: String
    public var subrole: String?
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var title: String?
    public var placeholder: String?
    public var enabled: Bool
    public var hidden: Bool
    public var frame: Rect
    public var children: [AXElement]

    public init(
        role: String, subrole: String? = nil, label: String? = nil, value: String? = nil,
        identifier: String? = nil, title: String? = nil, placeholder: String? = nil,
        enabled: Bool = true, hidden: Bool = false, frame: Rect, children: [AXElement] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.identifier = identifier
        self.title = title
        self.placeholder = placeholder
        self.enabled = enabled
        self.hidden = hidden
        self.frame = frame
        self.children = children
    }

    /// This element and all descendants, depth first.
    public var all: [AXElement] { [self] + children.flatMap(\.all) }
}
