import Foundation
import Testing
@testable import ChauffeurCore

@Suite @MainActor struct CLITests {
    final class Recorder: @unchecked Sendable { var calls: [(String, [String])] = [] }

    func env(booted: [DeviceInfo], cwd: URL = FileManager.default.temporaryDirectory, recorder: Recorder = Recorder(),
             vars: [String: String] = [:]) -> CLI.Environment {
        CLI.Environment(env: vars, cwd: cwd, devices: { booted }, send: { udid, args in
            recorder.calls.append((udid, args))
            return Output("from daemon")
        })
    }

    let a = DeviceInfo(udid: "AAAA-1", name: "iPhone 17 Pro", runtime: "iOS 26.2", state: "Booted")
    let b = DeviceInfo(udid: "BBBB-2", name: "iPhone 18 Pro", runtime: "iOS 27.0", state: "Shutdown")

    @Test func versionAndUsage() {
        #expect(CLI.handle(["--version"], env(booted: [])) == Output("chauffeur \(Chauffeur.version)"))
        #expect(CLI.handle([], env(booted: [])).exit == 64)
        #expect(CLI.handle(["help"], env(booted: [])) == Output(Usage.text))
    }

    @Test func forwardsToTheOnlyBootedSimulator() {
        let rec = Recorder()
        #expect(CLI.handle(["tap", "e4", "--long", "1"], env(booted: [a, b], recorder: rec)) == Output("from daemon"))
        #expect(rec.calls.count == 1 && rec.calls[0].0 == "AAAA-1" && rec.calls[0].1 == ["tap", "e4", "--long", "1"])
    }

    @Test func udidFlagAnywhereWins() {
        let rec = Recorder()
        _ = CLI.handle(["snapshot", "--udid", "BBBB-2", "--all"], env(booted: [a, b], recorder: rec))
        #expect(rec.calls[0].0 == "BBBB-2" && rec.calls[0].1 == ["snapshot", "--all"])
    }

    @Test func globalsStopAtDoubleDash() throws {
        let (udid, json, rest) = try CLI.globals(["find", "--udid", "BBBB-2", "--", "--udid", "--json"])
        #expect(udid == "BBBB-2" && !json && rest == ["find", "--", "--udid", "--json"])
        #expect(throws: ChauffeurError.self) { try CLI.globals(["snapshot", "--udid"]) }
    }

    @Test func jsonWrapsTheSameResult() {
        let rec = Recorder()
        let e = CLI.Environment(env: [:], cwd: FileManager.default.temporaryDirectory, devices: { [a] }, send: { udid, args in
            rec.calls.append((udid, args))
            return Output("tap e4 → changed", exit: 0, data: ["outcome": "changed"])
        })
        let out = CLI.handle(["tap", "--json", "e4"], e)
        #expect(out.text == #"{"data":{"outcome":"changed"},"exit":0,"text":"tap e4 → changed"}"#)
        #expect(rec.calls[0].1 == ["tap", "e4"])
        let failed = CLI.handle(["--json", "snapshot", "--udid"], env(booted: [a]))
        #expect(failed.exit == 64 && failed.text.hasPrefix(#"{"data":null,"exit":64,"text":"--udid needs a value"#))
    }

    @Test func appArgumentsAfterArgsAreForwardedUntouched() {
        let rec = Recorder()
        let out = CLI.handle(["launch", "dev.x", "--args", "--json", "--udid", "-v"], env(booted: [a], recorder: rec))
        #expect(out == Output("from daemon"))  // --json after --args belongs to the app: no JSON wrapping
        #expect(rec.calls[0].0 == "AAAA-1" && rec.calls[0].1 == ["launch", "dev.x", "--args", "--json", "--udid", "-v"])
    }

    @Test func badDoctorFlagIsAUsageError() {
        let out = CLI.handle(["doctor", "--lvie"], env(booted: [a]))
        #expect(out.exit == 64 && out.text.hasPrefix("unknown option --lvie"))
    }

    @Test func typosDoNotStartADaemon() {
        let rec = Recorder()
        let out = CLI.handle(["snapshto"], env(booted: [a], recorder: rec))
        #expect(out.exit == 64 && out.text.hasPrefix("unknown command \"snapshto\""))
        #expect(rec.calls.isEmpty)
    }

    @Test func targetErrorsSayWhatToDo() {
        let out = CLI.handle(["snapshot"], env(booted: [b]))
        #expect(out.exit == 1 && out.text.hasPrefix("no booted simulator"))
    }

    @Test func usePinsTheDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let used = CLI.handle(["use", "iPhone 18 Pro"], env(booted: [a, b], cwd: dir))
        #expect(used.exit == 0 && used.text.hasPrefix("using iPhone 18 Pro (iOS 27.0) BBBB-2"))
        let rec = Recorder()
        _ = CLI.handle(["find", "OK"], env(booted: [a, b], cwd: dir, recorder: rec))
        #expect(rec.calls[0].0 == "BBBB-2")
    }
}
