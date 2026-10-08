import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct AXProviderTests {
    // Dictionaries mimic the bridge: frames arrive as NSArray<NSNumber>.
    @Test func sweepTargetsAreChildlessBars() throws {
        let home = try Fixtures.ax("fixture-home")
        let targets = home.all.filter(AXProvider.isSweepTarget)
        #expect(targets.map(\.identifier) == ["Fixture", nil])  // nav-bar host, then the tab bar
        #expect(targets.last?.label == "Tab Bar")
    }

    @Test func gridCoversTheBar() {
        let pts = AXProvider.points(in: Rect(x: 0, y: 791, w: 402, h: 83))
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
        #expect(AXProvider.merge(hits, into: bar).children == [home, form])
    }

    @Test func filledBarsRenderAsChildren() throws {
        let filled = AXProvider.fillBars(try Fixtures.ax("fixture-home")) { frame in
            frame.y > 700
                ? [AXElement(role: "AXButton", label: "Home", value: "1", frame: Rect(x: 40, y: 795, w: 90, h: 50))]
                : []
        }
        var refs = RefTable()
        let body = Perception.build(root: filled, size: Size(w: 402, h: 874), previous: nil, refs: &refs, rev: 1)
            .bodyLines(all: false)
        #expect(body.suffix(2) == ["group \"Tab Bar\"", "  button \"Home\" [e6] value=\"1\""])
    }

    @Test func dictionariesBecomeElements() {
        let d: [String: Any] = [
            "role": "AXButton", "label": "OK", "enabled": false, "hidden": false,
            "frame": [1, 2, 3, 4].map { NSNumber(value: $0) },
            "children": [["role": "AXStaticText", "frame": [0, 0, 1, 1].map { NSNumber(value: $0) }, "children": []]],
        ]
        let e = AXElement(dictionary: d)
        #expect(e?.label == "OK" && e?.enabled == false && e?.frame == Rect(x: 1, y: 2, w: 3, h: 4))
        #expect(e?.children.first?.role == "AXStaticText")
        #expect(AXElement(dictionary: ["label": "no role"]) == nil)
    }
}
