import Foundation

public enum Orientation: String, Sendable {
    case portrait, landscape
}

/// Points, transport space and the edge guard (spec §6.5).
public enum Geometry {
    /// Touches closer than this to an edge trigger system gestures.
    public static let edgeMargin = 6.0

    /// Transport space: 0–1 in the portrait screen, clamped.
    public static func normalised(_ p: Point, screen: Size) -> Point {
        Point(x: min(max(p.x / screen.w, 0), 1), y: min(max(p.y / screen.h, 0), 1))
    }

    /// Why a touch at `p` must be refused, or nil when it is fine.
    public static func refusal(for p: Point, screen: Size, allowEdge: Bool) -> String? {
        guard p.x >= 0, p.y >= 0, p.x <= screen.w, p.y <= screen.h else {
            return "(\(fmt(p.x)),\(fmt(p.y))) is outside the screen (\(fmt(screen.w))×\(fmt(screen.h))pt)"
        }
        if allowEdge { return nil }
        let distances = [("left", p.x), ("right", screen.w - p.x), ("top", p.y), ("bottom", screen.h - p.y)]
        guard let (edge, d) = distances.first(where: { $0.1 < edgeMargin }) else { return nil }
        return "(\(fmt(p.x)),\(fmt(p.y))) is \(fmt(d))pt from the \(edge) edge; touches within "
            + "\(fmt(edgeMargin))pt of an edge trigger system gestures. Pass --edge to do it anyway"
    }

    /// The device type's screen is portrait; a wider-than-tall root means the UI is rotated.
    public static func orientation(root: Rect, screen: Size) -> Orientation {
        root.w > root.h && screen.h > screen.w ? .landscape : .portrait
    }

    /// Where to touch an element: switches near their right edge (S4), everything else at the centre.
    public static func tapPoint(role: String, frame: Rect) -> Point {
        guard role == "switch" else { return frame.center }
        return Point(x: max(frame.center.x, frame.maxX - 30), y: frame.center.y)
    }

    static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// Where to drag for a scroll (spec §6.7). "down" reveals content below, so the finger moves up.
public enum ScrollPlan {
    public static func defaultRegion(screen: Size) -> Rect {
        Rect(x: 0, y: screen.h * 0.2, w: screen.w, h: screen.h * 0.6)
    }

    /// A frame clipped to the visible screen (a partly off-screen container must not drag from an edge).
    public static func region(_ frame: Rect, screen: Size) -> Rect {
        let x0 = max(frame.x, 0), y0 = max(frame.y, 0)
        return Rect(x: x0, y: y0, w: max(0, min(frame.maxX, screen.w) - x0), h: max(0, min(frame.maxY, screen.h) - y0))
    }

    public static func drag(_ direction: String, in r: Rect) -> (from: Point, to: Point)? {
        let cx = r.center.x, cy = r.center.y
        let high = r.y + r.h * 0.25, low = r.y + r.h * 0.75
        let left = r.x + r.w * 0.25, right = r.x + r.w * 0.75
        switch direction {
        case "down": return (Point(x: cx, y: low), Point(x: cx, y: high))
        case "up": return (Point(x: cx, y: high), Point(x: cx, y: low))
        case "right": return (Point(x: right, y: cy), Point(x: left, y: cy))
        case "left": return (Point(x: left, y: cy), Point(x: right, y: cy))
        default: return nil
        }
    }
}
