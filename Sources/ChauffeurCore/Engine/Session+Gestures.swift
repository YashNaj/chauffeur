import ChauffeurBridge
import Foundation

extension Session {
    /// `x,y` in points.
    nonisolated static func point(_ text: String) -> Point? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1], x.isFinite, y.isFinite else { return nil }
        return Point(x: x, y: y)
    }

    func swipeCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, flags: ["--edge"], usage: "usage: chauffeur swipe <x1,y1> <x2,y2> [--edge]")
        guard let fromText = a.next(), let toText = a.next(), let from = Self.point(fromText),
            let to = Self.point(toText)
        else {
            throw ChauffeurError.usage(a.usage)
        }
        try a.done()
        let (device, _) = try connect()
        // --edge lifts the guard only: the digitizer still sends interior touches, so system edge gestures may not fire.
        for p in [from, to] {
            if let refusal = Geometry.refusal(for: p, screen: device.size, allowEdge: a.flag("--edge")) {
                return Output("swipe refused: \(refusal)", exit: 1)
            }
        }
        let (before, settled) = try baseline()
        let label =
            "swipe (\(Geometry.fmt(from.x)),\(Geometry.fmt(from.y)))→(\(Geometry.fmt(to.x)),\(Geometry.fmt(to.y)))"
        var report = try act(label, target: nil, before: before, baselineSettled: settled, needsMove: true) {
            Gestures.drag($0, from: from, to: to, screen: device.size)
        }
        if report.outcome == .noEffect {
            report.hints = ["nothing moved: start the swipe on scrollable or draggable content, or use scroll"]
        }
        return Output(report.render(), exit: report.exitCode, data: report.json)
    }

    func buttonCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur button <home|lock|siri|volume-up|volume-down>")
        guard let name = a.next(), let button = HardwareButton(rawValue: name) else {
            throw ChauffeurError.usage(a.usage)
        }
        try a.done()
        _ = try transportsReady()
        guard let hid else { throw ChauffeurError.bridge("no HID client") }
        return try actWithoutTouch(
            "button \(name)", capMs: 4000, note: "a button press leaves no touch evidence",
            hints: ["the press may have nothing visible to change here (volume, already home); run snapshot"]
        ) {
            press(button, hid: hid) ? nil : "the HID send failed; run chauffeur doctor --live"
        }
    }

    func press(_ button: HardwareButton, hid: CHHIDClient) -> Bool {
        func send(_ down: Bool) -> Bool {
            if let source = button.source { return hid.button(source: source, down: down) }
            return hid.usage(page: 0x0C, usage: button.consumerUsage ?? 0, down: down)
        }
        let down = send(true)
        usleep(UInt32(button.holdMs) * 1000)
        return send(false) && down
    }
}
