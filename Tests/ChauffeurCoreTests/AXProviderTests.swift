import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct AXProviderTests {
    // Dictionaries mimic the bridge: frames arrive as NSArray<NSNumber>.
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
