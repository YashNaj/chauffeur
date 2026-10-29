import Foundation

extension Session {
    func typeCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, flags: ["--submit"], usage: "usage: chauffeur type <ref> \"<text>\" [--submit]")
        let submit = a.flag("--submit")
        guard let ref = a.next(), let text = a.text(), !text.isEmpty else { throw ChauffeurError.usage(a.usage) }
        let (device, _) = try connect()
        let network = self.network.start(appPid: app?.pid) { ax?.frontmostPID() }
        let (before, settled) = try baseline()
        let field = try before.resolve(ref: ref, refs: refs)
        guard Perception.textEntry.contains(field.role) else {
            return Output(
                "\(ref) is a \(field.role), not a text field; type needs a textfield, securefield or searchfield ref",
                exit: .error)
        }
        let secure = field.role == "securefield"
        let label = "type \(ref)" + (secure ? " (\(text.count) characters)" : " " + Perception.quote(text))
        // `runOne` traced a provisional, text-free `type` until the field is known; a plain field may show its text.
        traceArgs = secure ? Self.redactedType(ref: ref, characters: text.count, submit: submit) : nil

        let aimed = try aim(ref, in: before)
        inputDeviceLost = false
        let focus = try act("tap \(aimed.label)", target: field, before: before, baselineSettled: settled) { [self] in
            Gestures.tap($0, at: aimed.point, screen: device.size, clock: clock)
        }
        switch focus.outcome {
        case .notDelivered, .intercepted:
            return Output(
                "\(label) → not typed: focusing the field failed\n" + focus.render(), exit: .noEffect,
                data: ["focus": focus.json])
        default:
            break
        }
        let focused = last ?? before
        // The focus tap reset (a failed send) or dropped the input device: the field is not known to be focused.
        guard !inputDeviceLost else { throw ChauffeurError.bridge("HID client lost after focusing") }
        let keyboard = try inputDeviceReady().keyboard(clock: clock)
        let method: String
        let sent: Bool
        let typingNet = self.network.atTouch(network)
        if Keys.typeable(text) && text.count <= 15 {
            method = "keys"
            sent = keyboard.type(text)
        } else {
            method = "paste"
            let copied = try shell.simctl(["pbcopy", udid], stdin: text, timeout: 15)
            guard copied.status == 0 else {
                return Output("\(label) → not typed: simctl pbcopy exited \(copied.status)", exit: .error)
            }
            sent = keyboard.press(Keys.v, modifiers: [Keys.command])
        }
        defer {
            // A pasted password must not stay on the simulator's pasteboard (M1 review minor); cleared once verified.
            if secure && method == "paste" { _ = try? shell.simctl(["pbcopy", udid], stdin: "", timeout: 15) }
        }
        guard sent else {
            return Output(
                "\(label) → NOT DELIVERED: key events failed to send\nhint: input transport unhealthy — run `chauffeur doctor --live`",
                exit: .noEffect)
        }

        // Verify the text before Return, so a submit that navigates away can't hide a failed entry (I2).
        let (typed, settle) = try observe(minMs: 150, capMs: 1500)
        let now = typed.node(identity: field.identity)
        let verdict = TypeCheck.verify(
            typed: text, before: focused.node(identity: field.identity) ?? field,
            after: now, submitted: false)
        var report = TypeReport(
            action: label, method: method, verdict: verdict, value: now?.value, settledMs: settle.elapsedMs)
        if verdict == .ok {
            // Typing's requests: one look after the grace, no window. The field is the proof, so a late request can't
            // make it a false NO EFFECT.
            report.requests = self.network.sampleOnce(typingNet)
            report.requestElapsedMs = clock.nowMs() - typingNet.touchMs
        }
        guard submit, verdict == .ok else { return Output(report.render(), exit: report.exitCode, data: report.json) }

        guard keyboard.press(Keys.returnKey) else {
            return Output(
                report.render() + "\nsubmit → NOT DELIVERED: Return failed to send", exit: .noEffect,
                data: report.json.merging(["submit": "notDelivered"]))
        }
        let after = try observe(minMs: 150, capMs: 1500).snapshot
        let changed = after.hash != typed.hash
        let submitted =
            changed
            ? "submit → changed · rev \(typed.rev)→\(after.rev)\n"
                + Diff.lines(from: typed, to: after).joined(separator: "\n")
            : "submit → NO EFFECT · nothing changed after Return"
        return Output(
            report.render() + "\n" + submitted, exit: changed ? .ok : .noEffect,
            data: report.json.merging(["submit": changed ? "changed" : "noEffect"]))
    }

    /// What the trace keeps of `type` into a secure field: everything but the text.
    nonisolated static func redactedType(ref: String, characters: Int, submit: Bool) -> [String] {
        ["type"] + (submit ? ["--submit"] : []) + ["--", ref, "<secret: \(characters) characters>"]
    }

    /// A `type` command line with its text hidden, for the trace and for batch reports: the text may be a password and
    /// it is only known to be harmless once the field resolves to a non-secure one. Lenient: it never throws.
    nonisolated static func provisionalType(_ argv: [String]) -> [String] {
        var submit = false
        var dataOnly = false
        var words: [String] = []
        for token in argv.dropFirst() {
            if !dataOnly, token == "--" {
                dataOnly = true
                continue
            }
            if !dataOnly, token.hasPrefix("--"), token.count > 2 {
                if token == "--submit" { submit = true }
                continue
            }
            words.append(token)
        }
        var out = ["type"] + (submit ? ["--submit"] : []) + ["--"]
        if let ref = words.first { out.append(ref) }
        let text = words.dropFirst().joined(separator: " ")
        if !text.isEmpty { out.append("<text: \(text.count) characters>") }
        return out
    }

    /// `argv` as it may be shown or traced before anything is known about its target.
    nonisolated static func shown(_ argv: [String]) -> [String] {
        argv.first == "type" ? provisionalType(argv) : argv
    }
}
