import Foundation
import Testing

@testable import ChauffeurCore

final class FakeClock: SettleClock {
    var now = 0
    func nowMs() -> Int { now }
    func sleep(ms: Int) { now += ms }
}

enum Fixtures {
    /// An accessibility tree recorded in M0 (`spikes/fixtures/ax`).
    static func ax(_ name: String) throws -> AXElement {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ax"))
        return try JSONDecoder().decode(AXElement.self, from: Data(contentsOf: url))
    }

    /// A crash report trimmed from the M0 fixture crash (`Fixtures/crash`).
    static func crash(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "ips", subdirectory: "Fixtures/crash"))
        return try Data(contentsOf: url)
    }

    /// Apple networking log lines recorded in M4b step 0 (`Fixtures/network`), as `LogTap` stores them.
    static func network(_ name: String) throws -> [LogLine] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/network"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { row in
            let o = try #require(try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: String])
            return LogRedact.line(
                LogLine(
                    time: "00:00:00.000", level: o["level"] ?? "default", message: o["message"] ?? "",
                    sender: o["sender"]))
        }
    }
}

/// Finds the first element whose label, identifier or value contains `text`.
func element(_ root: AXElement, _ text: String) -> AXElement? {
    root.all.first { e in
        [e.label, e.identifier, e.value].contains { $0?.localizedCaseInsensitiveContains(text) == true }
    }
}
