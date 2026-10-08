import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct ModelTests {
    @Test func decodesM0Fixture() throws {
        let root = try Fixtures.ax("fixture-form")
        #expect(root.role == "AXApplication")
        #expect(root.label == "Fixture")
        let email = try #require(root.all.first { $0.identifier == "email" })
        #expect(email.value == "Email")
        #expect(email.frame.x == 32 && email.frame.w == 338)
        #expect(root.all.contains { $0.subrole == "AXSecureTextField" })
    }

    @Test func rectGeometry() {
        let r = Rect(x: 10, y: 20, w: 100, h: 50)
        #expect(r.maxX == 110 && r.maxY == 70)
        #expect(r.center == Point(x: 60, y: 45))
        #expect(r.contains(Point(x: 10, y: 70)))
        #expect(!r.contains(Point(x: 9, y: 30)))
        #expect(r.intersects(Rect(x: 100, y: 60, w: 50, h: 50)))
        #expect(!r.intersects(Rect(x: 110, y: 20, w: 5, h: 5)))  // touching edges only
        #expect(Rect(x: 0, y: 0, w: 0, h: 10).isEmpty)
    }

    @Test func rectCodesAsArray() throws {
        let data = try JSONEncoder().encode(Rect(x: 1, y: 2, w: 3, h: 4))
        #expect(String(decoding: data, as: UTF8.self) == "[1,2,3,4]")
        #expect(try JSONDecoder().decode(Rect.self, from: data) == Rect(x: 1, y: 2, w: 3, h: 4))
    }

    @Test func theReleaseVersionIsSet() {
        #expect(Chauffeur.version == "0.1.0")
    }
}
