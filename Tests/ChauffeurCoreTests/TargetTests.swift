import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct TargetTests {
    let a = DeviceInfo(udid: "AAAA-1", name: "iPhone 17 Pro", runtime: "iOS 26.2", state: "Booted")
    let b = DeviceInfo(udid: "BBBB-2", name: "iPhone 18 Pro", runtime: "iOS 27.0", state: "Shutdown")
    let c = DeviceInfo(udid: "CCCC-3", name: "iPhone 17 Pro", runtime: "iOS 27.0", state: "Shutdown")

    @Test func precedence() throws {
        #expect(try Target.resolve(flag: "BBBB-2", env: "AAAA-1", configUDID: "AAAA-1", devices: [a, b]) == "BBBB-2")
        #expect(try Target.resolve(flag: nil, env: "bbbb-2", configUDID: "AAAA-1", devices: [a, b]) == "BBBB-2")
        #expect(try Target.resolve(flag: nil, env: nil, configUDID: "BBBB-2", devices: [a, b]) == "BBBB-2")
        #expect(try Target.resolve(flag: nil, env: nil, configUDID: nil, devices: [a, b]) == "AAAA-1")
    }

    @Test func namesPreferTheBootedMatch() throws {
        #expect(try Target.match("iPhone 17 Pro", in: [a, b, c]).udid == "AAAA-1")
        #expect(throws: ChauffeurError.self) { try Target.match("iPhone 17 Pro", in: [c, DeviceInfo(udid: "D", name: "iPhone 17 Pro", runtime: "iOS 26.2", state: "Shutdown")]) }
        #expect(throws: ChauffeurError.self) { try Target.match("Pixel", in: [a]) }
    }

    @Test func noneOrSeveralBooted() {
        #expect(throws: ChauffeurError.noBootedSimulator) { try Target.resolve(flag: nil, env: nil, configUDID: nil, devices: [b]) }
        let a2 = DeviceInfo(udid: "EEEE-5", name: "iPad", runtime: "iOS 26.2", state: "Booted")
        #expect(throws: ChauffeurError.severalBooted([a.summary, a2.summary])) {
            try Target.resolve(flag: nil, env: nil, configUDID: nil, devices: [a, a2])
        }
    }

    @Test func configIsFoundFromSubdirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-target-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Target.writeConfig(udid: "BBBB-2", in: root)
        #expect(Target.readConfig(from: sub) == "BBBB-2")
        try FileManager.default.removeItem(at: root)
    }

    @Test(.timeLimit(.minutes(1))) func noConfigAnywhereEndsAtTheRoot() {
        // Walking up from a directory with no .chauffeur.json above it must stop at "/" (it used to loop forever).
        let dir = FileManager.default.temporaryDirectory  // a directory URL: walks "/" → "/.." → … without a root check
        #expect(Target.readConfig(from: dir) == nil)
    }
}
