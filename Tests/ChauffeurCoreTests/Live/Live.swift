import Foundation

@testable import ChauffeurCore

/// Live tests run only with CHAUFFEUR_LIVE_UDID set to a booted simulator, and must run serially because
/// every suite drives the same simulator. `scripts/live.sh <udid>` is the one way to run them.
enum Live {
    static let udid = ProcessInfo.processInfo.environment["CHAUFFEUR_LIVE_UDID"]
    static var enabled: Bool { udid != nil }
    /// The reboot test runs only when asked for by name: it shuts the simulator down and boots it again, and the
    /// boot's load lands on whatever runs next. `scripts/live.sh` runs it alone, last.
    static var reboot: Bool { udid != nil && ProcessInfo.processInfo.environment["CHAUFFEUR_LIVE_REBOOT"] != nil }
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

    /// The host's 1-minute load average (`getloadavg`).
    static func load() -> Double {
        var averages = [Double](repeating: 0, count: 1)
        return getloadavg(&averages, 1) == 1 ? averages[0] : 0
    }

    /// After a boot: waits until the 1-minute load is under `max`, at most `seconds`; returns the seconds waited, or
    /// nil when the load was still `max` or more at the end.
    static func waitForQuietHost(under max: Double = 10, atMost seconds: Int = 300) -> Int? {
        var waited = 0
        while load() >= max {
            if waited >= seconds { return nil }
            sleep(5)
            waited += 5
        }
        return waited
    }
}
