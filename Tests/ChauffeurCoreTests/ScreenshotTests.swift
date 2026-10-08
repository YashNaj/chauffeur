import CoreGraphics
import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ScreenshotTests {
    let phone = Size(w: 402, h: 874)  // iPhone 17 Pro, captured at 1206×2622 px

    @Test func fullScreenshotsAreOnePixelPerPoint() throws {
        let plan = try #require(ShotPlan.make(imageW: 1206, imageH: 2622, screen: phone, zoom: nil))
        #expect(
            plan
                == ShotPlan(
                    crop: Rect(x: 0, y: 0, w: 1206, h: 2622), width: 402, height: 874, pxPerPt: 1,
                    region: Rect(x: 0, y: 0, w: 402, h: 874)))
        let pad = try #require(ShotPlan.make(imageW: 2064, imageH: 2752, screen: Size(w: 1032, h: 1376), zoom: nil))
        #expect(pad.width == 1032 && pad.height == 1376 && pad.pxPerPt == 1)
    }

    @Test func theLongEdgeIsCappedAt1568() throws {
        let huge = try #require(ShotPlan.make(imageW: 2000, imageH: 3000, screen: Size(w: 2000, h: 3000), zoom: nil))
        #expect(huge.height == 1568 && huge.width == 1045)
        let wholeZoom = try #require(
            ShotPlan.make(imageW: 1206, imageH: 2622, screen: phone, zoom: Rect(x: 0, y: 0, w: 402, h: 874)))
        #expect(wholeZoom.height == 1568 && wholeZoom.width == 721)
    }

    @Test func zoomsKeepNativeDensityAndClipToTheScreen() throws {
        let button = try #require(
            ShotPlan.make(imageW: 1206, imageH: 2622, screen: phone, zoom: Rect(x: 16, y: 318.3, w: 370, h: 52)))
        #expect(
            button.crop == Rect(x: 48, y: 955, w: 1110, h: 156) && button.width == 1110 && button.height == 156
                && button.pxPerPt == 3)
        let clipped = try #require(
            ShotPlan.make(imageW: 1206, imageH: 2622, screen: phone, zoom: Rect(x: -10, y: 800, w: 100, h: 200)))
        #expect(clipped.region == Rect(x: 0, y: 800, w: 90, h: 74) && clipped.width == 270 && clipped.height == 222)
        #expect(ShotPlan.make(imageW: 1206, imageH: 2622, screen: phone, zoom: Rect(x: 500, y: 0, w: 10, h: 10)) == nil)
    }

    @Test func zoomRegionsParse() {
        #expect(Session.rect("16,318.3,370,52") == Rect(x: 16, y: 318.3, w: 370, h: 52))
        for bad in ["1,2,3", "1,2,0,4", "a,b,c,d", "1,2,3,-4"] { #expect(Session.rect(bad) == nil, "\(bad)") }
    }

    /// Reads one pixel as (r, g, b).
    func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    @Test func aCropKeepsTheTopOfTheImageOnTopThroughJPEG() throws {
        // 30×60 pixels: blue, with the top half red (CoreGraphics' origin is bottom-left, so the top half is y 30…60).
        let context = try #require(
            CGContext(
                data: nil, width: 30, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 60))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 30, width: 30, height: 30))
        let image = try #require(context.makeImage())
        let plan = try #require(
            ShotPlan.make(imageW: 30, imageH: 60, screen: Size(w: 10, h: 20), zoom: Rect(x: 0, y: 0, w: 10, h: 10)))
        #expect(plan.crop == Rect(x: 0, y: 0, w: 30, h: 30) && plan.width == 30 && plan.height == 30)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cht-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect((Screenshot.writeJPEG(try #require(Screenshot.render(image, plan)), to: url) ?? 0) > 0)
        let back = try #require(Screenshot.load(url))
        #expect(back.width == 30 && back.height == 30)
        let (r, g, b) = pixel(back, x: 15, y: 15)
        #expect(r > 200 && g < 60 && b < 60, "expected the red top half, got \(r),\(g),\(b)")
    }
}
