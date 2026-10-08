import Foundation

extension Session {
    /// `x,y,w,h` in points.
    nonisolated static func rect(_ text: String) -> Rect? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
            [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0
        else { return nil }
        return Rect(x: x, y: y, w: w, h: h)
    }

    func screenshotCommand(_ argv: [String]) throws -> Output {
        let a = try Args(argv, options: ["--zoom"], usage: "usage: chauffeur screenshot [--zoom <ref|x,y,w,h>]")
        try a.done()
        let (device, _) = try connect()
        var zoom: Rect?
        var subject = ""
        if let z = a.option("--zoom") {
            if z.wholeMatch(of: /e\d+/) != nil {
                zoom = try observe(minMs: 0, capMs: 1500).snapshot.resolve(ref: z, refs: refs).frame
                subject = " " + z
            } else if let r = Self.rect(z) {
                zoom = r
                subject = " " + [r.x, r.y, r.w, r.h].map(Geometry.fmt).joined(separator: ",")
            } else {
                throw ChauffeurError.usage(
                    "--zoom expects a ref like e4 or x,y,w,h in points, got \(Perception.quote(z))\n" + a.usage)
            }
        }
        let shot = try capture(screen: device.size, zoom: zoom)
        return Output("screenshot\(subject) → " + shot.line, data: shot.json)
    }

    /// One encoded screenshot: the file and how its pixels map to points.
    struct Shot {
        var path: String
        var plan: ShotPlan
        var bytes: Int

        var line: String {
            let size = "\(plan.width)×\(plan.height) px · \(max(1, bytes / 1024)) KB"
            let r = plan.region
            if r.x == 0 && r.y == 0 && plan.pxPerPt == 1 { return "\(path) · \(size) · 1 px = 1 pt" }
            let d = Screenshot.density(plan.pxPerPt)
            return
                "\(path) · \(size) · region \(Geometry.fmt(r.x)),\(Geometry.fmt(r.y)),\(Geometry.fmt(r.w)),\(Geometry.fmt(r.h)) pt "
                + "at \(d) px/pt: point = (\(Geometry.fmt(r.x)) + x/\(d), \(Geometry.fmt(r.y)) + y/\(d))"
        }

        var json: JSON {
            [
                "path": .string(path), "width": JSON(plan.width), "height": JSON(plan.height), "bytes": JSON(bytes),
                "pxPerPt": JSON(plan.pxPerPt),
                "region": [JSON(plan.region.x), JSON(plan.region.y), JSON(plan.region.w), JSON(plan.region.h)],
            ]
        }
    }

    /// Captures the screen with simctl, then crops, scales and encodes it into the artifacts folder (spec §6.5).
    func capture(screen: Size, zoom: Rect?) throws -> Shot {
        let dir = StatePaths.artifacts(udid)
        try StatePaths.ensureDir(StatePaths.dir)
        try StatePaths.ensureDir(dir)
        let raw = dir.appendingPathComponent("capture.png")
        defer { try? FileManager.default.removeItem(at: raw) }
        let r = try SimCtl.run(["io", udid, "screenshot", "--type=png", "--mask=ignored", raw.path], timeout: 30)
        guard r.status == 0, let image = Screenshot.load(raw) else {
            throw ChauffeurError.failed("screenshot failed: " + SimCtl.message(r))
        }
        guard let plan = ShotPlan.make(imageW: image.width, imageH: image.height, screen: screen, zoom: zoom) else {
            throw ChauffeurError.failed(
                "the zoom region is outside the screen (\(Geometry.fmt(screen.w))×\(Geometry.fmt(screen.h)) pt)")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss-SSS"
        let url = dir.appendingPathComponent("shot-\(formatter.string(from: Date()))\(zoom == nil ? "" : "-zoom").jpg")
        guard let rendered = Screenshot.render(image, plan), let bytes = Screenshot.writeJPEG(rendered, to: url) else {
            throw ChauffeurError.failed("could not encode the screenshot")
        }
        pruneShots(in: dir, keep: 40)
        return Shot(path: url.path, plan: plan, bytes: bytes)
    }

    /// Keeps the newest `keep` screenshots.
    func pruneShots(in dir: URL, keep: Int) {
        let key = URLResourceKey.contentModificationDateKey
        let shots = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [key])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("shot-") && $0.pathExtension == "jpg" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for old in shots.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }
}
