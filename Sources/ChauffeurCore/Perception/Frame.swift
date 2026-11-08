/// One read of the tree, the unit the settle loop compares: the root, and the web views' fingerprint, 0 until the
/// web-views plan computes it in `poll`. Equal frames hash equal, so settling is today's.
struct Frame: Hashable {
    var root: AXElement
    var fingerprint = 0
}
