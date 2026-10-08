import Foundation
import Testing
@testable import ChauffeurCore

@Suite(.enabled(if: Live.enabled), .serialized)
@MainActor struct ScreenshotLiveTests {
    @Test func screenshotsAreOnePixelPerPointJPEGs() throws {
        try Live.launchFixture()
        let s = Session(udid: Live.udid!)
        defer { s.shutdown() }
        #expect(s.run(["wait", "Show alert", "--timeout", "15"]).exit == 0)
        let full = s.run(["screenshot"])
        #expect(full.exit == 0 && full.text.hasPrefix("screenshot → /") && full.text.hasSuffix(" · 1 px = 1 pt"), "\(full.text)")
        let path = try #require(full.data?["path"]?.string)
        let image = try #require(Screenshot.load(URL(fileURLWithPath: path)))
        let size = try Device(udid: Live.udid!).size
        #expect(Double(image.width) == size.w && Double(image.height) == size.h, "\(image.width)×\(image.height) vs \(size)")

        let zoom = s.run(["screenshot", "--zoom", try ref(s, "Show alert")])
        #expect(zoom.exit == 0 && zoom.text.contains(" px/pt: point = ("), "\(zoom.text)")
        let both = s.run(["snapshot", "--screenshot"])
        #expect(both.exit == 0 && both.text.contains("\nscreenshot → /"), "\(both.text)")
    }
}
