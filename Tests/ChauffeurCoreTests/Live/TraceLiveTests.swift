import Foundation
import Testing
@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct TraceLiveTests {
    @Test func actionsAreTracedByIdentityAndSecretsAreNot() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cht-trace-\(UUID().uuidString).jsonl")
        s.traceFile = url
        defer { s.shutdown(); try? FileManager.default.removeItem(at: url) }
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        #expect(s.run(["tap", try ref(s, "tab:Form")]).exit == 0)
        let typed = s.run(["type", try ref(s, "securefield:"), "hunter2"])
        #expect(typed.exit == 0, "\(typed.text)")

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("hunter2"))
        let entries = try text.split(separator: "\n").map { try JSONDecoder().decode(TraceEntry.self, from: Data($0.utf8)) }
        let tap = try #require(entries.first { $0.args.first == "tap" })
        #expect(tap.target?.role == "tab" && tap.target?.name == "Form" && tap.exit == 0)
        let type = try #require(entries.last { $0.args.first == "type" })
        #expect(type.args.last == "<secret: 7 characters>" && type.target?.role == "securefield")
    }
}
