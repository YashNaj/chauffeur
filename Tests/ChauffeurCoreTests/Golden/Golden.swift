import Foundation
import Testing

/// Pins agent-facing text byte for byte against `Fixtures/golden/<name>`.
/// `CHAUFFEUR_GOLDEN_RECORD=1` writes the file into the source tree instead of comparing.
enum Golden {
    /// How many lines of unified diff a failure shows.
    static let diffLines = 20

    static func check(_ name: String, _ actual: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = sourceURL(name)
        if ProcessInfo.processInfo.environment["CHAUFFEUR_GOLDEN_RECORD"] == "1" {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(actual.utf8).write(to: url)
            } catch {
                Issue.record("could not record Fixtures/golden/\(name): \(error)", sourceLocation: sourceLocation)
            }
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            Issue.record(
                "no golden Fixtures/golden/\(name); record with CHAUFFEUR_GOLDEN_RECORD=1",
                sourceLocation: sourceLocation)
            return
        }
        let expected = String(decoding: data, as: UTF8.self)
        if Data(actual.utf8) != data {
            Issue.record(
                "Fixtures/golden/\(name) differs (- golden, + actual):\n\(diff(expected, actual))",
                sourceLocation: sourceLocation)
        }
    }

    /// The golden in the source tree, next to this file's `Fixtures`.
    private static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden").appendingPathComponent(name)
    }

    /// A line-by-line diff starting at the first difference, at most `diffLines` lines long.
    static func diff(_ expected: String, _ actual: String) -> String {
        let old = expected.components(separatedBy: "\n")
        let new = actual.components(separatedBy: "\n")
        let first = (0..<max(old.count, new.count)).first { old[safe: $0] != new[safe: $0] } ?? 0
        var out = ["@@ line \(first + 1) @@"]
        for i in first..<max(old.count, new.count) where out.count <= diffLines {
            if old[safe: i] == new[safe: i] {
                if let line = old[safe: i] { out.append("  \(line)") }
                continue
            }
            if let line = old[safe: i] { out.append("- \(line)") }
            if let line = new[safe: i] { out.append("+ \(line)") }
        }
        return out.prefix(diffLines + 1).joined(separator: "\n")
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
