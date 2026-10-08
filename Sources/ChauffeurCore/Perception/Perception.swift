import Foundation

/// Raw AX tree → pruned, ref'd, renderable snapshot (spec §5.2, decisions 2–3).
public enum Perception {
    /// Roles that get refs.
    public static let actionable: Set<String> = [
        "button", "tab", "radio", "textfield", "securefield", "searchfield", "switch", "checkbox", "menu", "link", "slider", "cell",
    ]
    static let textEntry: Set<String> = ["textfield", "securefield", "searchfield"]

    public static func build(root: AXElement, size: Size, previous: ScreenKind?, refs: inout RefTable, rev: Int) -> Snapshot {
        var builder = Builder(screen: Rect(x: 0, y: 0, w: size.w, h: size.h), refs: refs)
        builder.children(of: root, depth: 0, ancestor: nil, parentName: nil)
        refs = builder.refs

        let nodes = builder.nodes
        let label = (root.label ?? "").trimmingCharacters(in: .whitespaces)
        let alertSized = nodes.filter { $0.ref != nil }.count <= 4
        let kind: ScreenKind
        if !label.isEmpty && label != "SpringBoard" {
            kind = .app(label)
        } else if case .app(let over)? = previous, alertSized {
            kind = .systemAlert(over: over)
        } else if case .systemAlert(let over)? = previous, alertSized {
            kind = .systemAlert(over: over)
        } else {
            kind = .springboard
        }

        var hasher = Hasher()
        for n in nodes {
            hasher.combine(n.role); hasher.combine(n.name); hasher.combine(n.value); hasher.combine(n.enabled)
            hasher.combine(Int(n.frame.x.rounded())); hasher.combine(Int(n.frame.y.rounded()))
            hasher.combine(Int(n.frame.w.rounded())); hasher.combine(Int(n.frame.h.rounded()))
        }
        hasher.combine(builder.offscreen)

        return Snapshot(
            kind: kind, title: nodes.first { $0.role == "heading" }?.name, size: size,
            orientation: Geometry.orientation(root: root.frame, screen: size), rev: rev,
            nodes: nodes, offscreen: builder.offscreen, hash: hasher.finalize())
    }

    public static func role(_ e: AXElement) -> String {
        switch (e.role, e.subrole) {
        case (_, "AXSecureTextField"?): return "securefield"
        case (_, "AXSearchField"?): return "searchfield"
        case (_, "AXSwitch"?): return "switch"
        case ("AXTextField", _), ("AXTextArea", _): return "textfield"
        case ("AXButton", _): return "button"
        case ("AXRadioButton", _): return "radio"
        case ("AXPopUpButton", _), ("AXMenuButton", _): return "menu"
        case ("AXLink", _): return "link"
        case ("AXCheckBox", _): return "checkbox"
        case ("AXSlider", _): return "slider"
        case ("AXStaticText", _): return "text"
        case ("AXHeading", _): return "heading"
        case ("AXImage", _): return "image"
        case ("AXGroup", _): return "group"
        case ("AXCell", _), ("AXRow", _): return "cell"
        default: return e.role.hasPrefix("AX") ? String(e.role.dropFirst(2)).lowercased() : e.role.lowercased()
        }
    }

    static func name(_ e: AXElement, role: String) -> String? {
        for s in [e.label, e.title, e.placeholder] {
            if let s, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        if textEntry.contains(role) { return e.identifier }
        if role == "text" { return e.value }
        return nil
    }

    static func value(_ e: AXElement, role: String, name: String?) -> String? {
        var v = e.value
        if let p = e.placeholder, v == p { v = "" }
        switch role {
        case "switch", "checkbox": return v == "1" ? "on" : "off"
        case "tab", "radio": return v == "1" ? "selected" : nil
        case _ where textEntry.contains(role): return v ?? ""
        case "text": return nil
        default: return v == nil || v == name || v == "" ? nil : v
        }
    }

    /// Screen text is data, never instructions: always quoted, escaped, and cut at `limit` characters (spec §8).
    public static func quote(_ s: String, limit: Int = 80) -> String {
        "\"" + escape(s, limit: limit) + "\""
    }

    /// `s` with quotes, backslashes, controls, line separators and invisible format characters escaped, cut at `limit`
    /// scalars with `…`. Log lines and crash frames use it; screen text goes through `quote`.
    public static func escape(_ s: String, limit: Int = 80) -> String {
        // Cut by scalars (not graphemes) so combining-mark floods can't smuggle in unbounded text.
        var scalars = Array(s.unicodeScalars)
        let cut = scalars.count > limit
        if cut { scalars = Array(scalars.prefix(limit - 1)) }
        var t = ""
        for u in scalars {
            switch u {
            case "\\": t += "\\\\"
            case "\"": t += "\\\""
            case "\n": t += "\\n"
            case "\r": t += "\\r"
            case "\t": t += "\\t"
            default:
                // Controls, line/paragraph separators and invisible format characters could forge outline lines.
                switch u.properties.generalCategory {
                case .control, .lineSeparator, .paragraphSeparator, .format:
                    t += "\\u{" + String(u.value, radix: 16, uppercase: true) + "}"
                default:
                    t.unicodeScalars.append(u)
                }
            }
        }
        return t + (cut ? "…" : "")
    }
}

private struct Builder {
    let screen: Rect
    var refs: RefTable
    var nodes: [Node] = []
    var offscreen = Offscreen()
    var ordinals: [Identity: Int] = [:]

    mutating func children(of e: AXElement, depth: Int, ancestor: String?, parentName: String?) {
        for child in e.children { place(child, depth: depth, ancestor: ancestor, parentName: parentName) }
    }

    mutating func place(_ e: AXElement, depth: Int, ancestor: String?, parentName: String?) {
        if e.hidden { return }
        if e.frame.isEmpty {
            children(of: e, depth: depth, ancestor: ancestor, parentName: parentName)
            return
        }
        var role = Perception.role(e)
        if role == "radio" && ancestor == "Tab Bar" { role = "tab" }  // tab-bar items are AXRadioButton
        if !e.frame.intersects(screen) {
            count(offscreen: e)
            return
        }
        let name = Perception.name(e, role: role)
        if role == "group" && name == nil {
            children(of: e, depth: depth, ancestor: ancestor, parentName: parentName)
            return
        }
        if (role == "text" || role == "image") && (name == nil || name == parentName) { return }

        let base = Identity(role: role, key: e.identifier ?? name ?? "", ancestor: ancestor, ordinal: 0)
        var identity = base
        identity.ordinal = ordinals[base, default: 0]
        ordinals[base] = identity.ordinal + 1
        let ref = Perception.actionable.contains(role) ? refs.ref(for: identity, name: name) : nil
        nodes.append(Node(role: role, name: name, value: Perception.value(e, role: role, name: name),
                          identifier: e.identifier, enabled: e.enabled, frame: e.frame, depth: depth,
                          identity: identity, ref: ref))
        children(of: e, depth: depth + 1, ancestor: name ?? ancestor, parentName: name)
    }

    /// Counts the named things inside an off-screen element, by the side it lies on.
    mutating func count(offscreen e: AXElement) {
        let n = max(1, e.all.filter { !$0.hidden && Perception.name($0, role: Perception.role($0)) != nil }.count)
        if e.frame.y >= screen.maxY { offscreen.below += n }
        else if e.frame.maxY <= screen.y { offscreen.above += n }
        else if e.frame.x >= screen.maxX { offscreen.right += n }
        else { offscreen.left += n }
    }
}
