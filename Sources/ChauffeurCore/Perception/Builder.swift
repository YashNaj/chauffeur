struct Builder {
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
        nodes.append(
            Node(
                role: role, name: name, value: Perception.value(e, role: role, name: name),
                identifier: e.identifier, enabled: e.enabled, frame: e.frame, depth: depth,
                identity: identity, ref: ref))
        children(of: e, depth: depth + 1, ancestor: name ?? ancestor, parentName: name)
    }

    /// Counts the named things inside an off-screen element, by the side it lies on.
    mutating func count(offscreen e: AXElement) {
        let n = max(1, e.all.filter { !$0.hidden && Perception.name($0, role: Perception.role($0)) != nil }.count)
        if e.frame.y >= screen.maxY {
            offscreen.below += n
        } else if e.frame.maxY <= screen.y {
            offscreen.above += n
        } else if e.frame.x >= screen.maxX {
            offscreen.right += n
        } else {
            offscreen.left += n
        }
    }
}
