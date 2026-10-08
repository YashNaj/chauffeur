import Foundation
@testable import ChauffeurCore

/// Live tests run only with CHAUFFEUR_LIVE_UDID set to a booted simulator, and must run serially because
/// every suite drives the same simulator: `CHAUFFEUR_LIVE_UDID=<udid> swift test --no-parallel`.
enum Live {
    static let udid = ProcessInfo.processInfo.environment["CHAUFFEUR_LIVE_UDID"]
    static var enabled: Bool { udid != nil }
    static let fixture = "dev.chauffeur.fixture"
    /// repo/Tests/ChauffeurCoreTests/Live/Live.swift → repo
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Failure: Error, CustomStringConvertible { var description: String }

    /// Builds the fixture app and returns the path of `Fixture.app`.
    static func buildFixture() throws -> String {
        let build = Shell.run("/bin/bash", [repo.path + "/Tests/FixtureApp/build.sh"], timeout: 300)
        guard build.status == 0, let app = build.out.split(separator: "\n").last.map(String.init) else {
            throw Failure(description: "fixture build failed: \(build.err)")
        }
        return app
    }

    /// Builds and installs the fixture app, then launches a fresh instance of it.
    static func launchFixture() throws {
        let app = try buildFixture()
        guard let udid else { throw Failure(description: "CHAUFFEUR_LIVE_UDID not set") }
        try SimCtl.run(["install", udid, app], timeout: 120)
        try SimCtl.run(["terminate", udid, fixture])
        let launch = try SimCtl.run(["launch", udid, fixture], timeout: 60)
        guard launch.status == 0 else { throw Failure(description: "launch failed: \(launch.out)") }
    }
}
