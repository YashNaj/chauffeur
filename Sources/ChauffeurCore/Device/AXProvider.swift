import ChauffeurBridge
import Foundation

extension AXElement {
    init?(dictionary d: [String: Any]) {
        guard let role = d["role"] as? String,
            let f = d["frame"] as? [NSNumber], f.count == 4
        else { return nil }
        self.init(
            role: role, subrole: d["subrole"] as? String, label: d["label"] as? String, value: d["value"] as? String,
            identifier: d["identifier"] as? String, title: d["title"] as? String,
            placeholder: d["placeholder"] as? String,
            enabled: (d["enabled"] as? Bool) ?? true, hidden: (d["hidden"] as? Bool) ?? false,
            frame: Rect(x: f[0].doubleValue, y: f[1].doubleValue, w: f[2].doubleValue, h: f[3].doubleValue),
            children: ((d["children"] as? [[String: Any]]) ?? []).compactMap(AXElement.init(dictionary:)))
    }
}

/// Reads the frontmost tree and fills the bars the walk leaves empty (decision 1).
@MainActor
public final class AXProvider {
    private let reader: CHAXReader
    private var cache: (key: Int, result: AXElement)?

    public init(sim: CHSimulator) throws {
        do { reader = try CHAXReader(simulator: sim) } catch { throw ChauffeurError.bridge(error.localizedDescription) }
    }

    /// The raw walk: fast, used by settle polling. Nil when nothing answers.
    public func read() -> AXElement? {
        reader.frontmostTree().flatMap { AXElement(dictionary: $0) }
    }

    /// One process's tree, whatever is in front. Used to tell a poisoned bridge from a silent simulator.
    public func read(pid: Int32) -> AXElement? {
        reader.tree(pid: pid).flatMap { AXElement(dictionary: $0) }
    }

    /// Why a walk found nothing: is the app in front an empty shell (no accessibility server), and does a hit-test at
    /// `center` answer (it does on a poisoned bridge)?
    public func probe(center: Point) -> (frontmostIsEmptyApp: Bool, screenAnswers: Bool) {
        let front = reader.frontmostTree()
        let empty = front.map { (($0["children"] as? [Any]) ?? []).isEmpty } ?? false
        return (empty, reader.element(at: CGPoint(x: center.x, y: center.y)) != nil)
    }

    /// The walk plus hit-test results inside childless bars, cached per raw tree.
    public func complete(_ root: AXElement) -> AXElement {
        let key = root.hashValue
        if let cache, cache.key == key { return cache.result }
        let result = Self.fillBars(root) { frame in
            Self.points(in: frame).compactMap { p in
                self.reader.element(at: CGPoint(x: p.x, y: p.y)).flatMap { AXElement(dictionary: $0) }
            }
        }
        cache = (key, result)
        return result
    }

    nonisolated static func isSweepTarget(_ e: AXElement) -> Bool {
        e.role == "AXGroup" && e.children.isEmpty && !e.frame.isEmpty && e.frame.h <= 140
    }

    nonisolated static func points(in frame: Rect, step: Double = 32) -> [Point] {
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

    nonisolated static func fillBars(_ e: AXElement, sweep: (Rect) -> [AXElement]) -> AXElement {
        if isSweepTarget(e) { return merge(sweep(e.frame), into: e) }
        var copy = e
        copy.children = e.children.map { fillBars($0, sweep: sweep) }
        return copy
    }
}
