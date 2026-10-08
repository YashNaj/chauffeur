import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ShellTests {
    @Test func capturesOutputAndStdin() {
        let r = Shell.run("/bin/cat", [], stdin: "hello")
        #expect(r.status == 0 && r.out == "hello" && !r.timedOut)
    }

    @Test func capturesStderrSeparately() {
        let r = Shell.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(r.status == 3 && r.out == "out\n" && r.err == "err\n")
    }

    @Test func aMissingExecutableFailsFast() {
        let start = Date()
        let r = Shell.run("/no/such/tool", [])
        #expect(r.status == -1 && r.out.isEmpty && r.err.hasPrefix("cannot run /no/such/tool"))
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func timesOutInsteadOfHanging() {
        let start = Date()
        let r = Shell.run("/bin/sleep", ["5"], timeout: 0.5)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func parsesSimctlDeviceList() throws {
        let json = """
            {"devices": {
              "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                {"udid": "AF7CFC76-936D-4E67-98F7-102C682E7ECD", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true}],
              "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                {"udid": "4474DB35-730B-4017-AAB3-367700816901", "name": "iPhone 18 Pro", "state": "Shutdown", "isAvailable": true},
                {"udid": "00000000-0000-0000-0000-000000000000", "name": "Gone", "state": "Shutdown", "isAvailable": false}]
            }}
            """
        let devices = try SimCtl.parseDevices(Data(json.utf8))
        #expect(devices.count == 2)
        #expect(
            devices[0]
                == DeviceInfo(
                    udid: "AF7CFC76-936D-4E67-98F7-102C682E7ECD", name: "iPhone 17 Pro", runtime: "iOS 26.2",
                    state: "Booted"))
        #expect(devices[0].booted && !devices[1].booted)
        #expect(devices[1].summary == "iPhone 18 Pro (iOS 27.0) 4474DB35-730B-4017-AAB3-367700816901 Shutdown")
    }
}
