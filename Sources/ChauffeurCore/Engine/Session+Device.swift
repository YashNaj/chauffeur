import Foundation

/// Simulator settings (spec §5.1): privacy permissions, simulated location, push payloads, appearance.
extension Session {
    /// `simctl help privacy` services. `notifications` is not one of them (S2). Nonisolated: the MCP tool list reads it.
    nonisolated static let privacyServices: Set<String> = [
        "all", "calendar", "contacts-limited", "contacts", "location", "location-always", "photos-add", "photos",
        "media-library", "microphone", "motion", "reminders", "siri",
    ]

    func permissionCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur permission <grant|revoke|reset> <service> [<bundle>]")
        guard let action = a.next(), ["grant", "revoke", "reset"].contains(action), let service = a.next() else {
            throw ChauffeurError.usage(a.usage)
        }
        if service == "notifications" {
            return Output(
                "permission \(action) notifications → not possible: simctl cannot change notification permission. "
                    + "Let the app ask, then tap Allow on the prompt (snapshot shows it as a system alert)", exit: 1)
        }
        guard Self.privacyServices.contains(service) else {
            throw ChauffeurError.usage(
                "unknown service \(Perception.quote(service)); one of: "
                    + Self.privacyServices.sorted().joined(separator: ", ") + "\n" + a.usage)
        }
        let bundle = a.positionals.isEmpty ? nil : try bundleArgument(&a)
        try a.done()
        if action != "reset" && bundle == nil {
            throw ChauffeurError.usage("\(action) needs the app's bundle id\n" + a.usage)
        }
        _ = try connect()
        // "Some permission changes will terminate the application" (simctl help privacy): if that is the launched app,
        // its exit is expected, not a crash.
        let tracked = (bundle ?? app?.bundle).flatMap { release($0) }
        let r = try SimCtl.run(["privacy", udid, action, service] + (bundle.map { [$0] } ?? []), timeout: 30)
        let note = tracked.flatMap { afterPermissionChange($0, waitMs: 1000) }
        guard r.status == 0 else {
            return Output("permission \(action) \(service) → FAILED: \(SimCtl.message(r))", exit: 1)
        }
        let done = ["grant": "granted", "revoke": "revoked", "reset": "reset"][action] ?? action
        let head = "permission \(action) \(service)" + (bundle.map { " \($0)" } ?? "") + " → \(done)"
        return Output(([head] + [note].compactMap { $0 }).joined(separator: "\n"))
    }

    /// After a permission change: follows the app again if it survived, or says the change ended it (not a crash).
    func afterPermissionChange(_ tracked: TrackedApp, waitMs: Int) -> String? {
        let deadline = clock.nowMs() + waitMs
        while isAlive(tracked.pid), clock.nowMs() < deadline { clock.sleep(ms: 100) }
        guard !isAlive(tracked.pid) else {
            track(tracked)
            return nil
        }
        return
            "note: the change ended \(tracked.bundle) (pid \(tracked.pid)); relaunch it: chauffeur launch \(tracked.bundle)"
    }

    func locationCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur location <lat,lon> | clear")
        guard let value = a.next() else { throw ChauffeurError.usage(a.usage) }
        try a.done()
        let args: [String]
        let shown: String
        if value == "clear" {
            args = ["clear"]
            shown = "cleared"
        } else {
            // simctl itself accepts 91,0: check the range here.
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let lat = parts[0], let lon = parts[1], (-90...90).contains(lat),
                (-180...180).contains(lon)
            else {
                throw ChauffeurError.usage(
                    "location expects latitude,longitude in degrees (-90…90, -180…180), got "
                        + Perception.quote(value) + "\n" + a.usage)
            }
            args = ["set", "\(lat),\(lon)"]
            shown = "set to \(lat),\(lon)"
        }
        _ = try connect()
        let r = try SimCtl.run(["location", udid] + args, timeout: 30)
        guard r.status == 0 else { return Output("location → FAILED: \(SimCtl.message(r))", exit: 1) }
        return Output("location → \(shown)")
    }

    func pushCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur push <bundle> <payload.json>")
        let bundle = try bundleArgument(&a)
        guard let raw = a.text() else { throw ChauffeurError.usage(a.usage) }
        let file = resolvePath(raw)
        guard let data = try? Data(contentsOf: file) else { return Output("push: cannot read \(file.path)", exit: 1) }
        if let problem = Self.pushProblem(data) { return Output("push: \(problem)", exit: 1) }
        _ = try connect()
        let r = try SimCtl.run(["push", udid, bundle, file.path], timeout: 30)
        guard r.status == 0 else { return Output("push \(bundle) → FAILED: \(SimCtl.message(r))", exit: 1) }
        return Output("push \(bundle) → sent (\(data.count)-byte payload)")
    }

    /// simctl's rules for a payload (`simctl help push`): a JSON object with an "aps" object, at most 4096 bytes.
    nonisolated static func pushProblem(_ data: Data) -> String? {
        guard data.count <= 4096 else { return "the payload is \(data.count) bytes; simctl accepts at most 4096" }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "the payload is not a JSON object"
        }
        guard object["aps"] is [String: Any] else {
            return #"the payload needs an "aps" object, e.g. {"aps":{"alert":"Hi"}}"#
        }
        return nil
    }

    func appearanceCommand(_ argv: [String]) throws -> Output {
        var a = try Args(argv, usage: "usage: chauffeur appearance <light|dark>")
        guard let mode = a.next(), mode == "light" || mode == "dark" else { throw ChauffeurError.usage(a.usage) }
        try a.done()
        _ = try connect()
        let before = try SimCtl.run(["ui", udid, "appearance"], timeout: 30).out.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let r = try SimCtl.run(["ui", udid, "appearance", mode], timeout: 30)
        guard r.status == 0 else { return Output("appearance \(mode) → FAILED: \(SimCtl.message(r))", exit: 1) }
        let after = try SimCtl.run(["ui", udid, "appearance"], timeout: 30).out.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard after == mode else {
            return Output(
                "appearance \(mode) → UNVERIFIED: the simulator now reports \(Perception.quote(after))", exit: 3)
        }
        return Output(
            "appearance → \(mode)" + (before == mode ? " (it already was)" : " (was \(Perception.escape(before)))"))
    }
}
