import Foundation

/// A JSON value: `--json` output data, MCP (JSON-RPC) messages and trace records.
/// Whole numbers encode without a fraction, so JSON-RPC ids such as `1` round-trip as `1`, not `1.0`.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    public var int: Int? { number.flatMap { $0.rounded() == $0 && abs($0) < 9.0e15 ? Int($0) : nil } }
    public var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public init(_ value: String?) { self = value.map { .string($0) } ?? .null }
    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: Double) { self = .number(value) }
    public init(_ values: [String]) { self = .array(values.map { .string($0) }) }

    /// Compact, single-line, sorted keys, unescaped slashes: one JSON-RPC or JSONL record.
    public func line() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    /// The same object with `extra` keys added (non-objects become an object holding only `extra`).
    public func merging(_ extra: [String: JSON]) -> JSON {
        var o = object ?? [:]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }
}

extension JSON: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .number(Double(i))
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            if d.rounded() == d, abs(d) < 9.0e15 { try c.encode(Int64(d)) } else { try c.encode(d) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
