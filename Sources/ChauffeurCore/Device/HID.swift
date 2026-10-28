import ChauffeurBridge
import Foundation

/// The simulator's HID input, and the one owner of the private `CHHIDClient`: the client is built on first use, and
/// dropped by `reset()` after a failed send so the next action builds a fresh one.
@MainActor
public final class HID: InputDevice {
    private let device: Device
    private var client: CHHIDClient?
    private var built: [any TouchTransport] = []

    public init(device: Device) { self.device = device }

    /// Builds the client if there is none. Throws the bridge's own error, which `doctor` shows as it is.
    func open() throws { _ = try opened() }

    /// The client, built if there is none. Private: the client never leaves this file.
    private func opened() throws -> CHHIDClient {
        if let client { return client }
        let made = try CHHIDClient(simulator: device.sim)
        client = made
        built = [DigitizerTransport(hid: made), MouseTransport(hid: made)]
        return made
    }

    /// `opened()` for a command: a bridge failure tells the agent to run doctor.
    private func connected() throws -> CHHIDClient {
        do {
            return try opened()
        } catch {
            throw ChauffeurError.bridge(error.localizedDescription)
        }
    }

    public func transports() throws -> [any TouchTransport] {
        _ = try connected()
        return built
    }

    public func keyboard(clock: any SettleClock) throws -> any TextInput {
        Keyboard(hid: try connected(), clock: clock)
    }

    public func press(_ button: HardwareButton, clock: any SettleClock) throws -> Bool {
        let hid = try connected()
        func send(_ down: Bool) -> Bool {
            if let source = button.source { return hid.button(source: source, down: down) }
            return hid.usage(page: 0x0C, usage: button.consumerUsage ?? 0, down: down)
        }
        let down = send(true)
        clock.sleep(ms: button.holdMs)
        return send(false) && down
    }

    public func reset() {
        client = nil
        built = []
    }
}

@MainActor
public final class DigitizerTransport: TouchTransport {
    public let name = "digitizer"
    public let supportsMove = true
    private let hid: CHHIDClient
    init(hid: CHHIDClient) { self.hid = hid }
    public func touch(_ p: Point, _ phase: TouchPhase) -> Bool {
        hid.digitizer(at: CGPoint(x: p.x, y: p.y), touching: phase != .up)
    }
}

@MainActor
public final class MouseTransport: TouchTransport {
    public let name = "mouse"
    public let supportsMove = false
    private let hid: CHHIDClient
    init(hid: CHHIDClient) { self.hid = hid }
    public func touch(_ p: Point, _ phase: TouchPhase) -> Bool {
        switch phase {
        case .down: return hid.mouse(at: CGPoint(x: p.x, y: p.y), down: true)
        case .up: return hid.mouse(at: CGPoint(x: p.x, y: p.y), down: false)
        case .move: return false
        }
    }
}

@MainActor
public struct Keyboard: TextInput {
    // Built by `HID` only: the two 15 ms waits go through `clock`.
    private let hid: CHHIDClient
    let clock: any SettleClock

    fileprivate init(hid: CHHIDClient, clock: any SettleClock) {
        self.hid = hid
        self.clock = clock
    }

    /// Types page-7 text (call only when `Keys.typeable`). ~35 ms per character (S4).
    public func type(_ text: String) -> Bool {
        var ok = true
        for c in text {
            guard let k = Keys.usage(for: c) else { return false }
            ok = press(k.usage, modifiers: k.shift ? [Keys.shift] : []) && ok
        }
        return ok
    }

    public func press(_ usage: UInt32, modifiers: [UInt32]) -> Bool {
        var ok = true
        for m in modifiers { ok = hid.key(usage: m, down: true) && ok }
        ok = hid.key(usage: usage, down: true) && ok
        clock.sleep(ms: 15)
        ok = hid.key(usage: usage, down: false) && ok
        for m in modifiers.reversed() { ok = hid.key(usage: m, down: false) && ok }
        clock.sleep(ms: 15)
        return ok
    }
}
