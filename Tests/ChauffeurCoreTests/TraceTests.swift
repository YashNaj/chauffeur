import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct TraceTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cht-trace-\(UUID().uuidString).jsonl")
    }

    func entries(_ url: URL) throws -> [TraceEntry] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(TraceEntry.self, from: Data($0.utf8)) }
    }

    let entry = TraceEntry(time: "2026-10-06T22:24:53.430Z", udid: "AF7C", args: ["tap", "e4"], exit: 0, ms: 340,
                           result: "tap e4 \"Sign in\" → changed", target: TraceTarget(ref: "e4", role: "button", name: "Sign in", id: "signIn"),
                           app: "com.example")

    @Test func appendsOnePrivateLinePerCommand() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        Trace.append(entry, to: url)
        Trace.append(entry, to: url)
        #expect(try entries(url) == [entry, entry])
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o600)
        let line = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")[0]
        #expect(line.hasPrefix(#"{"app":"com.example","args":["tap","e4"],"exit":0,"ms":340,"result":"#))
    }

    @Test func rotatesInsteadOfGrowingForever() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("1")) }
        for _ in 0..<3 { Trace.append(entry, to: url, rotateBytes: 500) }
        #expect(try entries(url).count == 1)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
    }

    @Test func secureTextNeverReachesTheTrace() {
        #expect(Session.redactedType(ref: "e3", characters: 7, submit: true) == ["type", "--submit", "--", "e3", "<secret: 7 characters>"])
    }

    @Test @MainActor func everyCommandButTheBatchItselfIsTraced() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = Session(udid: "ZZ000000-TEST")
        #expect(s.traceFile == nil)  // only the daemon keeps a trace
        s.traceFile = url
        _ = s.run(["tap"])
        _ = s.run(["do", "tap; logs"])
        let traced = try entries(url)
        #expect(traced.map(\.args) == [["tap"], ["tap"]])  // `do` itself and the command it never ran are absent
        #expect(traced[0].exit == 64 && traced[0].result.hasPrefix("usage: chauffeur tap") && traced[0].udid == "ZZ000000-TEST")
    }
}

@Suite @MainActor struct TraceSecretTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cht-trace-\(UUID().uuidString).jsonl")
    }

    @Test func typedTextIsNotTracedWhenTypeFailsBeforeTheFieldIsKnown() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = Session(udid: "ZZ000000-TEST")
        s.traceFile = url
        _ = s.run(["type", "e7", "hunter2"])  // no simulator: fails before the ref resolves
        _ = s.run(["type", "e7", "hunter2", "--bogus"])  // fails while parsing
        _ = s.run(["type", "--submit", "--", "e7", "--hunter", "2"])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("hunter2") && !text.contains("--hunter"))
        let args = try text.split(separator: "\n").map { try JSONDecoder().decode(TraceEntry.self, from: Data($0.utf8)).args }
        #expect(args == [["type", "--", "e7", "<text: 7 characters>"], ["type", "--", "e7", "<text: 7 characters>"],
                         ["type", "--submit", "--", "e7", "<text: 10 characters>"]])
    }

    @Test func batchResultsAndNotRunLinesHideTypedText() throws {
        let s = Session(udid: "ZZ000000-TEST")
        let out = try s.batchCommand(["tap; type e7 hunter2; type e8 --submit"])
        #expect(out.exit == 64)
        #expect(out.text.hasSuffix("not run: type -- e7 \"<text: 7 characters>\"; type --submit -- e8"))
        #expect(!out.text.contains("hunter2") && !(out.data?.line() ?? "").contains("hunter2"))
    }
}
