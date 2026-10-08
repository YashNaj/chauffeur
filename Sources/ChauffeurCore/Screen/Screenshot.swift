import CoreGraphics
import Foundation
import ImageIO

/// What to crop from a capture and how big to make it (spec §6.5): full screenshots are 1 px = 1 pt, zooms keep the
/// device's native density, and both stay within 1568 px on the long edge, so image coordinates map back to points.
public struct ShotPlan: Equatable, Sendable {
    public static let maxEdge = 1568.0
    /// The captured pixels to keep.
    public var crop: Rect
    /// Output size in pixels.
    public var width: Int
    public var height: Int
    /// Output pixels per screen point.
    public var pxPerPt: Double
    /// The region shown, in points.
    public var region: Rect

    /// `imageW`×`imageH`: the capture in pixels; `screen`: the device in points; `zoom`: a region in points, or nil.
    /// Nil when the zoom region lies outside the screen.
    public static func make(imageW: Int, imageH: Int, screen: Size, zoom: Rect?) -> ShotPlan? {
        guard imageW > 0, imageH > 0, screen.w > 0, screen.h > 0 else { return nil }
        let scale = Double(max(imageW, imageH)) / max(screen.w, screen.h)  // device pixels per point, any orientation
        let full = Rect(x: 0, y: 0, w: Double(imageW) / scale, h: Double(imageH) / scale)
        var region = full
        if let zoom {
            let x0 = max(zoom.x, 0)
            let y0 = max(zoom.y, 0)
            let x1 = min(zoom.maxX, full.w)
            let y1 = min(zoom.maxY, full.h)
            guard x1 > x0, y1 > y0 else { return nil }
            region = Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        }
        let density = min(zoom == nil ? 1 : scale, maxEdge / max(region.w, region.h))
        let crop = Rect(
            x: (region.x * scale).rounded(), y: (region.y * scale).rounded(),
            w: (region.w * scale).rounded(), h: (region.h * scale).rounded())
        return ShotPlan(
            crop: crop, width: max(1, Int((region.w * density).rounded())),
            height: max(1, Int((region.h * density).rounded())), pxPerPt: density, region: region)
    }
}

/// ImageIO and CoreGraphics steps of a screenshot.
public enum Screenshot {
    public static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Crops and scales `image` as `plan` says (sRGB, no alpha). `cropping(to:)` uses top-left pixel coordinates.
    public static func render(_ image: CGImage, _ plan: ShotPlan) -> CGImage? {
        let c = plan.crop
        guard let cropped = image.cropping(to: CGRect(x: c.x, y: c.y, width: c.w, height: c.h)),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: plan.width, height: plan.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
        return context.makeImage()
    }

    /// Writes a JPEG and returns its size in bytes.
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) -> Int? {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }

    /// `3`, or `1.794` when the density is not whole.
    static func density(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.3f", v) }
}
