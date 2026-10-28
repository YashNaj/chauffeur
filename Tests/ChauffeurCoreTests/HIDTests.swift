import Foundation
import Testing

@testable import ChauffeurCore

@Suite @MainActor struct HIDTests {
    let screen = Size(w: 402, h: 874)

    @Test func fakeInputsHandOutTheDigitizerThenTheMouse() throws {
        #expect(try FakeInputs().transports().map(\.name) == ["digitizer", "mouse"])
    }

    @Test func aTapIsDownThenUpAndWaitsExactlyItsHold() {
        for holdMs in [50, 120] {
            let transport = FakeTransport(name: "digitizer", supportsMove: true)
            let clock = FakeClock()
            #expect(Gestures.tap(transport, at: Point(x: 201, y: 437), screen: screen, holdMs: holdMs, clock: clock))
            #expect(transport.touches.map { $0.1 } == [.down, .up])
            #expect(transport.touches.map { $0.0 } == [Point(x: 0.5, y: 0.5), Point(x: 0.5, y: 0.5)])
            #expect(clock.now == holdMs)
        }
    }

    @Test func aDragIsDownTwelveMovesAndUpSixteenMillisecondsApart() {
        let transport = FakeTransport(name: "digitizer", supportsMove: true)
        let clock = FakeClock()
        #expect(
            Gestures.drag(
                transport, from: Point(x: 201, y: 650), to: Point(x: 201, y: 250), screen: screen, clock: clock))
        #expect(transport.touches.map { $0.1 } == [.down] + Array(repeating: .move, count: 12) + [.up])
        #expect(clock.now == 12 * 16)
    }

    @Test func aDragNeedsATransportThatMoves() {
        let transport = FakeTransport(name: "mouse", supportsMove: false)
        let clock = FakeClock()
        #expect(
            !Gestures.drag(
                transport, from: Point(x: 201, y: 650), to: Point(x: 201, y: 250), screen: screen, clock: clock))
        #expect(transport.touches.isEmpty && clock.now == 0)
    }

    @Test func aFakeTextInputAnswersItsPressesInOrderAndHoldsTheLast() {
        let keyboard = FakeTextInput(presses: [true, false])
        #expect(keyboard.press(Keys.returnKey))
        #expect(!keyboard.press(Keys.v, modifiers: [Keys.command]))
        #expect(!keyboard.press(Keys.returnKey))
        #expect(keyboard.pressed.map { $0.usage } == [Keys.returnKey, Keys.v, Keys.returnKey])
        #expect(keyboard.pressed.map { $0.modifiers } == [[], [Keys.command], []])
    }

    @Test func aFailedSendResetsTheInputDeviceAndTheSessionKeepsIt() throws {
        let inputs = FakeInputs(transports: [
            FakeTransport(name: "digitizer", supportsMove: true, sends: false),
            FakeTransport(name: "mouse", supportsMove: false, sends: false),
        ])
        let s = Session(
            udid: "ZZ000000-TEST",
            environment: .scripted(ax: ScriptedAX(frames: [try Fixtures.ax("fixture-home")]), inputs: inputs))
        _ = s.run(["tap", "201,344"])
        #expect(inputs.resetCount == 1)
        #expect(inputs.fakes[0].touches.map { $0.1 } == [.down, .up])
        #expect(s.inputDevice === inputs)
        _ = s.run(["tap", "201,344"])
        #expect(inputs.resetCount == 2)
        #expect(inputs.fakes[0].touches.count == 4)
    }

    /// Compile-only: no simulator in unit tests.
    func hidIsAnInputDevice(_ device: Device) -> any InputDevice { HID(device: device) }
}
