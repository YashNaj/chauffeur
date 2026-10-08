import Testing

@testable import ChauffeurCore

@Suite struct GeometryTests {
    let screen = Size(w: 402, h: 874)

    @Test func normalisesAndClamps() {
        #expect(Geometry.normalised(Point(x: 201, y: 437), screen: screen) == Point(x: 0.5, y: 0.5))
        #expect(Geometry.normalised(Point(x: -5, y: 900), screen: screen) == Point(x: 0, y: 1))
    }

    @Test func edgeGuard() {
        #expect(Geometry.refusal(for: Point(x: 201, y: 437), screen: screen, allowEdge: false) == nil)
        let left = Geometry.refusal(for: Point(x: 3, y: 400), screen: screen, allowEdge: false)
        #expect(left?.contains("3pt from the left edge") == true)
        #expect(left?.contains("--edge") == true)
        #expect(
            Geometry.refusal(for: Point(x: 200, y: 870), screen: screen, allowEdge: false)?.contains("bottom") == true)
        #expect(Geometry.refusal(for: Point(x: 3, y: 400), screen: screen, allowEdge: true) == nil)
    }

    @Test func offScreenIsAlwaysRefused() {
        let r = Geometry.refusal(for: Point(x: 500, y: 10), screen: screen, allowEdge: true)
        #expect(r?.contains("outside the screen (402×874pt)") == true)
    }

    @Test func orientationFromRootFrame() {
        #expect(Geometry.orientation(root: Rect(x: 0, y: 0, w: 402, h: 874), screen: screen) == .portrait)
        #expect(Geometry.orientation(root: Rect(x: 0, y: 0, w: 874, h: 402), screen: screen) == .landscape)
    }

    @Test func switchesAreTappedNearTheirRightEdge() {
        // S4: a SwiftUI Toggle row ignores a tap at its centre.
        #expect(Geometry.tapPoint(role: "switch", frame: Rect(x: 16, y: 272, w: 370, h: 52)) == Point(x: 356, y: 298))
        #expect(Geometry.tapPoint(role: "switch", frame: Rect(x: 0, y: 0, w: 40, h: 20)) == Point(x: 20, y: 10))
        #expect(Geometry.tapPoint(role: "button", frame: Rect(x: 16, y: 318, w: 370, h: 52)) == Point(x: 201, y: 344))
    }

    @Test func formatsWholeAndFractionalPoints() {
        #expect(Geometry.fmt(402) == "402")
        #expect(Geometry.fmt(235.666) == "235.7")
    }

    @Test func scrollPlans() throws {
        let region = ScrollPlan.defaultRegion(screen: screen)
        #expect(abs(region.y - 174.8) < 0.01 && abs(region.h - 524.4) < 0.01)
        let down = try #require(ScrollPlan.drag("down", in: region))
        #expect(down.from.x == 201 && abs(down.from.y - 568.1) < 0.01 && abs(down.to.y - 305.9) < 0.01)
        let right = try #require(ScrollPlan.drag("right", in: Rect(x: 0, y: 100, w: 400, h: 100)))
        #expect(right.from == Point(x: 300, y: 150) && right.to == Point(x: 100, y: 150))
        #expect(ScrollPlan.drag("sideways", in: region) == nil)
    }
}
