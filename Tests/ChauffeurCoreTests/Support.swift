import Foundation
import Testing

@testable import ChauffeurCore

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
}

/// Finds the first element whose label, identifier or value contains `text`.
func element(_ root: AXElement, _ text: String) -> AXElement? {
    root.all.first { e in
        [e.label, e.identifier, e.value].contains { $0?.localizedCaseInsensitiveContains(text) == true }
    }
}
