import Foundation

/// Hit tests on a grid inside the elements `isTarget` picks, merged in as their children (M1 decision 1: the bars the
/// walk leaves empty). `bars` is today's sweep: a 32 pt step over childless groups up to 140 pt high. One entry is
/// cached by the frame's hash, so settling and a verdict compare like with like (spec §8); the web-views plan is
/// what adds the fingerprint to that key and gives verdicts a fresh sweep.
@MainActor
final class Sweep {
    let step: Double
    let isTarget: (AXElement) -> Bool
    private var cache: (key: Int, result: AXElement)?

    init(step: Double, isTarget: @escaping (AXElement) -> Bool) {
        self.step = step
        self.isTarget = isTarget
    }

    static func bars() -> Sweep {
        Sweep(step: 32) { $0.role == "AXGroup" && $0.children.isEmpty && !$0.frame.isEmpty && $0.frame.h <= 140 }
    }

    func complete(_ frame: Frame, hits: (Point) -> AXElement?) -> AXElement {
        let key = frame.hashValue
        if let cache, cache.key == key { return cache.result }
        let result = fill(frame.root, hits: hits)
        cache = (key, result)
        return result
    }

    /// The connection is gone: the next `complete` sweeps afresh, whatever the frame (`Session.drop()`).
    func forget() { cache = nil }

    private func fill(_ e: AXElement, hits: (Point) -> AXElement?) -> AXElement {
        if isTarget(e) { return Self.merge(Self.points(in: e.frame, step: step).compactMap(hits), into: e) }
        var copy = e
        copy.children = e.children.map { fill($0, hits: hits) }
        return copy
    }

    nonisolated static func points(in frame: Rect, step: Double) -> [Point] {
        var points: [Point] = []
        var y = frame.y + step / 2
        while y < frame.maxY {
            var x = frame.x + step / 2
            while x < frame.maxX {
                points.append(Point(x: x, y: y))
                x += step
            }
            y += step
        }
        return points
    }

    nonisolated static func merge(_ hits: [AXElement], into container: AXElement) -> AXElement {
        var kids: [AXElement] = []
        for h in hits
        where container.frame.contains(h.frame.center) && h.frame != container.frame
            && h.role != "AXApplication" && !(h.role == "AXGroup" && h.label == nil)
        {
            if !kids.contains(where: { $0.role == h.role && $0.label == h.label && $0.frame == h.frame }) {
                kids.append(h)
            }
        }
        var filled = container
        filled.children = kids.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
        return filled
    }
}
