import AppKit

// Renders one PNG per event: a title, the last 12 lines of the run, and counters. Writes frames.txt for ffmpeg concat.
let a = CommandLine.arguments
guard a.count == 6, let w = Int(a[3]), let h = Int(a[4]) else {
    print("usage: panel.swift <events.tsv> <outdir> <width> <height> <title>"); exit(2)
}
let rows = try String(contentsOfFile: a[1], encoding: .utf8).split(separator: "\n")
    .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count == 6 }
let out = URL(fileURLWithPath: a[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let mono = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
let bold = NSFont.systemFont(ofSize: 22, weight: .semibold)
var lines: [(String, NSColor)] = []
var concat = ""
func colour(_ kind: String, _ text: String) -> NSColor {
    if kind == "call" { return .systemBlue }
    if kind == "answer" { return .white }
    if kind == "detail" && text.hasPrefix("hint:") { return .systemYellow }
    if text.contains("NO EFFECT") || text.contains("UNVERIFIED") || text.contains("APP CRASHED") || text.contains("APP EXITED") { return .systemOrange }
    return NSColor(white: 0.75, alpha: 1)
}
for (i, r) in rows.enumerated() {
    lines.append(((r[1] == "call" ? "› " : r[1] == "answer" ? "✓ " : "  ") + r[2], colour(r[1], r[2])))
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSColor(white: 0.08, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    (a[5] as NSString).draw(at: NSPoint(x: 24, y: h - 48), withAttributes: [.font: bold, .foregroundColor: NSColor.white])
    let counters = "turns \(r[3])   tokens \(r[4])   $\(r[5])   \(r[0])s"
    (counters as NSString).draw(at: NSPoint(x: 24, y: h - 80), withAttributes: [.font: mono, .foregroundColor: NSColor.systemGreen])
    var y = h - 130
    for (text, c) in lines.suffix(12) {
        let rect = NSRect(x: 24, y: y - 40, width: w - 48, height: 56)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: mono, .foregroundColor: c])
        y -= 60
    }
    image.unlockFocus()
    let name = String(format: "%04d.png", i + 1)
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    let now = Double(r[0]) ?? 0
    let next = i + 1 < rows.count ? (Double(rows[i + 1][0]) ?? now) : now + 4
    concat += "file '\(name)'\nduration \(max(0.1, next - now))\n"
}
if !rows.isEmpty { concat += "file '\(String(format: "%04d.png", rows.count))'\n" }
try concat.write(to: out.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
