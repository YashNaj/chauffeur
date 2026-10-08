import Testing

@testable import ChauffeurCore

@Suite struct KeysTests {
    func key(_ c: Character) -> String? {
        Keys.usage(for: c).map { String(format: "%02X", $0.usage) + ($0.shift ? "+shift" : "") }
    }

    @Test func page7Mapping() {
        #expect(key("a") == "04")
        #expect(key("A") == "04+shift")
        #expect(key("1") == "1E")
        #expect(key("@") == "1F+shift")
        #expect(key("_") == "2D+shift")
        #expect(key("é") == nil)
    }

    @Test func typeableDecidesHIDOrPaste() {
        #expect(Keys.typeable("Ab@1.test_X"))
        #expect(!Keys.typeable("café"))
        #expect(!Keys.typeable("🚕"))
    }
}
