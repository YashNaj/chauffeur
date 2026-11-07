import Foundation
import Testing

@testable import ChauffeurCore

@Suite @MainActor struct SweepTests {
    @Test func sweepTargetsAreChildlessBars() throws {
        let home = try Fixtures.ax("fixture-home")
        let targets = home.all.filter(Sweep.bars().isTarget)
        #expect(targets.map(\.identifier) == ["Fixture", nil])  // nav-bar host, then the tab bar
        #expect(targets.last?.label == "Tab Bar")
    }

    @Test func gridCoversTheBar() {
        let pts = Sweep.points(in: Rect(x: 0, y: 791, w: 402, h: 83), step: 32)
        #expect(pts.count == 39)
        #expect(pts.first == Point(x: 16, y: 807))
    }

    @Test func mergeKeepsDistinctHitsInsideTheContainer() {
        let bar = AXElement(role: "AXGroup", label: "Tab Bar", frame: Rect(x: 0, y: 791, w: 402, h: 83))
        let home = AXElement(role: "AXButton", label: "Home", frame: Rect(x: 40, y: 795, w: 90, h: 50))
        let form = AXElement(role: "AXButton", label: "Form", frame: Rect(x: 270, y: 795, w: 90, h: 50))
        let hits = [
            form, home, home, bar,
            AXElement(role: "AXGroup", frame: Rect(x: 0, y: 791, w: 200, h: 83)),
            AXElement(role: "AXButton", label: "Elsewhere", frame: Rect(x: 0, y: 10, w: 50, h: 20)),
        ]
        #expect(Sweep.merge(hits, into: bar).children == [home, form])
    }

    @Test func aScriptedHitFillsTheBar() throws {
        let ax = ScriptedAX(frames: [])
        let button = AXElement(
            role: "AXButton", label: "Home", value: "1", frame: Rect(x: 40, y: 795, w: 90, h: 50))
        ax.hits[Point(x: 48, y: 807)] = button
        let filled = Sweep.bars().complete(Frame(root: try Fixtures.ax("fixture-home"))) { ax.element(at: $0) }
        var refs = RefTable()
        let body = Perception.build(root: filled, size: Size(w: 402, h: 874), previous: nil, refs: &refs, rev: 1)
            .bodyLines(all: false)
        #expect(body.suffix(2) == ["group \"Tab Bar\"", "  button \"Home\" [e6] value=\"1\""])
    }

    @Test func theSameFrameIsServedFromTheCache() throws {
        let ax = ScriptedAX(frames: [])
        let sweep = Sweep.bars()
        let frame = Frame(root: try Fixtures.ax("fixture-home"))
        let first = sweep.complete(frame) { ax.element(at: $0) }
        let calls = ax.elementCalls
        #expect(calls > 0)
        #expect(sweep.complete(frame) { ax.element(at: $0) } == first)
        #expect(ax.elementCalls == calls)
    }
}
