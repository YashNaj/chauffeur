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

/// Reads the frontmost tree from the bridge.
@MainActor
public final class AXProvider: AXSource {
    private let reader: CHAXReader

    public init(sim: CHSimulator) throws {
        do { reader = try CHAXReader(simulator: sim) } catch { throw ChauffeurError.bridge(error.localizedDescription) }
    }

    public convenience init(device: Device) throws { try self.init(sim: device.sim) }

    /// The raw walk: fast, used by settle polling. Nil when nothing answers.
    public func read() -> AXElement? {
        reader.frontmostTree().flatMap { AXElement(dictionary: $0) }
    }

    /// The pid of the app in front; nil when the bridge doesn't say. Known even when that app has no tree.
    public func frontmostPID() -> Int32? {
        let pid = reader.frontmostPid()
        return pid > 0 ? pid : nil
    }

    /// One process's tree, whatever is in front. Used to tell a poisoned bridge from a silent simulator.
    public func read(pid: Int32) -> AXElement? {
        reader.tree(pid: pid).flatMap { AXElement(dictionary: $0) }
    }

    /// The element a hit-test at `point` lands on; nil when nothing answers.
    public func element(at point: Point) -> AXElement? {
        reader.element(at: CGPoint(x: point.x, y: point.y)).flatMap { AXElement(dictionary: $0) }
    }

    /// Why a walk found nothing: is the app in front an empty shell (no accessibility server), and does a hit-test at
    /// `center` answer (it does on a poisoned bridge)?
    public func probe(center: Point) -> (frontmostIsEmptyApp: Bool, screenAnswers: Bool) {
        let front = reader.frontmostTree()
        let empty = front.map { (($0["children"] as? [Any]) ?? []).isEmpty } ?? false
        return (empty, reader.element(at: CGPoint(x: center.x, y: center.y)) != nil)
    }
}
