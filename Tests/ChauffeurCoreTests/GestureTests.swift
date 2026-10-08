import Testing

@testable import ChauffeurCore

@Suite @MainActor struct GestureTests {
    @Test func pointsAreTwoFiniteNumbers() {
        #expect(Session.point("201,650") == Point(x: 201, y: 650))
        #expect(Session.point(" 10.5 , 20 ") == Point(x: 10.5, y: 20))
        for bad in ["201", "201,", ",650", "a,b", "1,2,3", "inf,1"] { #expect(Session.point(bad) == nil, "\(bad)") }
    }

    @Test func buttonsMapToIndigoSourcesOrConsumerUsages() {
        #expect(HardwareButton(rawValue: "home")?.source == 0x0)
        #expect(HardwareButton(rawValue: "siri")?.source == 0x400002)
        #expect(HardwareButton(rawValue: "volume-up")?.consumerUsage == 0xE9)
        #expect(HardwareButton(rawValue: "volume-down")?.source == nil)
        #expect(HardwareButton(rawValue: "power") == nil)
    }

    @Test func badArgumentsAreUsageErrorsBeforeTouchingTheSimulator() {
        let s = Session(udid: "ZZ000000-TEST")
        #expect(throws: ChauffeurError.self) { try s.swipeCommand(["201,650"]) }
        #expect(throws: ChauffeurError.self) { try s.swipeCommand(["201,650", "up"]) }
        #expect(throws: ChauffeurError.self) { try s.buttonCommand(["power"]) }
    }
}

@Suite @MainActor struct AimTests {
    func snapshot() -> Snapshot {
        var refs = RefTable()
        let root = AXElement(role: "AXApplication", label: "App", frame: Rect(x: 0, y: 0, w: 402, h: 874))
        return Perception.build(root: root, size: Size(w: 402, h: 874), previous: nil, refs: &refs, rev: 1)
    }

    @Test func malformedPointsAreUsageErrors() throws {
        let s = Session(udid: "ZZ000000-TEST")
        let snap = snapshot()
        for bad in ["1,2,abc", "nan,5", "inf,1", "1", "a,b", "1,2,3", "1,"] {
            #expect(
                throws: ChauffeurError.usage(
                    "expected a ref like e4 or a point like 201,344; got \(Perception.quote(bad))")
            ) {
                try s.aim(bad, in: snap)
            }
        }
        let ok = try s.aim(" 201 , 344", in: snap)
        #expect(ok.point == Point(x: 201, y: 344) && ok.label == "(201,344)")
    }
}
