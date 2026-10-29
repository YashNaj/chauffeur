import Foundation
import Testing

@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct InputLiveTests {
    func setUp() throws -> (Device, AXProvider, HID) {
        try Live.launchFixture()
        let device = try Device(udid: Live.udid!)
        return (device, try AXProvider(sim: device.sim), HID(device: device))
    }

    func tapAndExpectAlert(_ transport: any TouchTransport, _ device: Device, _ ax: AXProvider) throws {
        let home = try #require(waitForTree(ax) { element($0, "Show alert") != nil })
        let button = try #require(element(home, "Show alert"))
        #expect(Gestures.tap(transport, at: button.frame.center, screen: device.size, clock: SystemClock()))
        _ = try #require(
            waitForTree(ax, timeout: 3) { element($0, "Fixture alert") != nil }, "\(transport.name) tap did not land")
        // A just-presented alert drops touches for a few hundred ms even after its tree settles (measured
        // on iOS 26.2: tapping at settle+0 fails, settle+200 ms succeeds). Settle, then wait out that window.
        let settled = Settle.wait(minMs: 150, capMs: 2000, clock: SystemClock()) {
            () -> (value: AXElement, hash: Int)? in
            ax.read().map { ($0, $0.hashValue) }
        }
        usleep(400_000)
        let ok = try #require(settled.value?.all.first { $0.label == "OK" })
        #expect(Gestures.tap(transport, at: ok.frame.center, screen: device.size, clock: SystemClock()))
        #expect(waitForTree(ax, timeout: 3) { element($0, "alert ok") != nil } != nil)
    }

    @Test func digitizerTapLands() throws {
        let (device, ax, hid) = try setUp()
        try tapAndExpectAlert(try hid.transports()[0], device, ax)
    }

    @Test func mouseTapLands() throws {
        let (device, ax, hid) = try setUp()
        try tapAndExpectAlert(try hid.transports()[1], device, ax)
    }

    @Test func keyboardTypesIntoTheFocusedField() throws {
        let (device, ax, hid) = try setUp()
        let digitizer = try hid.transports()[0]
        let root = try #require(waitForTree(ax) { element($0, "Show alert") != nil })
        // Ruling (Task 10): tab items are AXRadioButton, not AXButton.
        let formTab = try #require(ax.complete(root).all.first { $0.label == "Form" && $0.role == "AXRadioButton" })
        #expect(Gestures.tap(digitizer, at: formTab.frame.center, screen: device.size, clock: SystemClock()))
        let form = try #require(waitForTree(ax) { $0.all.contains { $0.identifier == "email" } })
        let email = try #require(form.all.first { $0.identifier == "email" })
        print("email placeholder attribute: \(email.placeholder ?? "nil"), value: \(email.value ?? "nil")")
        #expect(Gestures.tap(digitizer, at: email.frame.center, screen: device.size, clock: SystemClock()))
        usleep(300_000)
        #expect(try hid.keyboard(clock: SystemClock()).type("Ab@1.test_X"))
        let typed = waitForTree(ax, timeout: 3) {
            $0.all.contains { $0.identifier == "email" && $0.value == "Ab@1.test_X" }
        }
        #expect(typed != nil)
    }
}
