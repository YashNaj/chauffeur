import Foundation

public enum TouchPhase: Sendable { case down, move, up }

/// One way of delivering touches (spec §6.1). Points are normalised 0–1 in the portrait screen.
@MainActor
public protocol TouchTransport: AnyObject {
    var name: String { get }
    var supportsMove: Bool { get }
    func touch(_ normalised: Point, _ phase: TouchPhase) -> Bool
}

/// What `Session` sends input through: `HID` in production, a fake in tests.
@MainActor
public protocol InputDevice: AnyObject {
    /// Digitizer first, then mouse. The same objects until `reset()`: `act` compares transports by identity.
    func transports() throws -> [any TouchTransport]
    func keyboard(clock: any SettleClock) throws -> any TextInput
    /// Presses and releases `button`, holding it for `button.holdMs`.
    func press(_ button: HardwareButton, clock: any SettleClock) throws -> Bool
    /// After a failed send: drop the client; the next call rebuilds it.
    func reset()
}

/// Key presses on the HID keyboard page (spec §5.1).
@MainActor
public protocol TextInput {
    /// Types page-7 text (call only when `Keys.typeable`).
    func type(_ text: String) -> Bool
    func press(_ usage: UInt32, modifiers: [UInt32]) -> Bool
}

extension TextInput {
    public func press(_ usage: UInt32) -> Bool { press(usage, modifiers: []) }
}

@MainActor
public enum Gestures {
    public static func tap(
        _ t: any TouchTransport, at p: Point, screen: Size, holdMs: Int = 50, clock: any SettleClock
    ) -> Bool {
        let n = Geometry.normalised(p, screen: screen)
        let down = t.touch(n, .down)
        clock.sleep(ms: holdMs)
        let up = t.touch(n, .up)
        return down && up
    }

    /// A straight drag in `steps` moves, `stepMs` apart. Needs a transport that supports moves.
    public static func drag(
        _ t: any TouchTransport, from a: Point, to b: Point, screen: Size, steps: Int = 12, stepMs: Int = 16,
        clock: any SettleClock
    ) -> Bool {
        guard t.supportsMove else { return false }
        var ok = t.touch(Geometry.normalised(a, screen: screen), .down)
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            clock.sleep(ms: stepMs)
            ok =
                t.touch(
                    Geometry.normalised(Point(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), screen: screen),
                    .move) && ok
        }
        return t.touch(Geometry.normalised(b, screen: screen), .up) && ok
    }
}

/// Hardware buttons (spec §5.1): home, lock and Siri are Indigo button events; volume is the HID consumer page.
public enum HardwareButton: String, CaseIterable, Sendable {
    case home, lock, siri
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"

    /// IndigoHIDMessageForButton event source (idb's ButtonEventSource values).
    public var source: UInt32? {
        switch self {
        case .home: 0x0
        case .lock: 0x1
        case .siri: 0x400002
        case .volumeUp, .volumeDown: nil
        }
    }

    /// HID consumer-page (0x0C) usage: Volume Increment / Volume Decrement.
    public var consumerUsage: UInt32? {
        switch self {
        case .volumeUp: 0xE9
        case .volumeDown: 0xEA
        default: nil
        }
    }

    /// Siri listens to a held press; the rest are clicks.
    public var holdMs: Int { self == .siri ? 600 : 100 }
}

public enum Keys {
    public static let shift: UInt32 = 0xE1
    public static let command: UInt32 = 0xE3
    public static let returnKey: UInt32 = 0x28
    public static let v: UInt32 = 0x19

    /// US-layout HID page-7 usage, or nil if page 7 cannot express the character (S4).
    public static func usage(for c: Character) -> (usage: UInt32, shift: Bool)? {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        if let i = letters.firstIndex(of: c) { return (0x04 + UInt32(i), false) }
        if c.isUppercase, let lower = c.lowercased().first, let i = letters.firstIndex(of: lower) {
            return (0x04 + UInt32(i), true)
        }
        if let i = Array("1234567890").firstIndex(of: c) { return (0x1E + UInt32(i), false) }
        if let i = Array("!@#$%^&*()").firstIndex(of: c) { return (0x1E + UInt32(i), true) }
        let table: [Character: (UInt32, Bool)] = [
            " ": (0x2C, false), "\n": (0x28, false), "-": (0x2D, false), "_": (0x2D, true), "=": (0x2E, false),
            "+": (0x2E, true), ".": (0x37, false), ",": (0x36, false), "/": (0x38, false), "?": (0x38, true),
            "'": (0x34, false), "\"": (0x34, true), ";": (0x33, false), ":": (0x33, true),
        ]
        return table[c].map { (usage: $0.0, shift: $0.1) }
    }

    public static func typeable(_ text: String) -> Bool { text.allSatisfy { usage(for: $0) != nil } }
}
