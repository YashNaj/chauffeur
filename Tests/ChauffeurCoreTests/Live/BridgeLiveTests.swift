import Testing
@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct BridgeLiveTests {
    @Test func resolvesTheBootedDevice() throws {
        let device = try Device(udid: Live.udid!)
        #expect(device.booted)
        #expect(device.size.w >= 375 && device.size.h >= 800)
        #expect(device.simulatorKitPath.hasSuffix("SimulatorKit"))
    }

    @Test func unknownUDIDIsABridgeError() {
        #expect(throws: ChauffeurError.self) { try Device(udid: "00000000-0000-0000-0000-000000000000") }
    }
}
