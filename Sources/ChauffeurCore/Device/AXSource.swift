/// Where `Session` reads the accessibility tree from: the bridge in production, a scripted source in tests.
@MainActor
public protocol AXSource: AnyObject {
    func read() -> AXElement?
    func read(pid: Int32) -> AXElement?
    func frontmostPID() -> Int32?
    func element(at point: Point) -> AXElement?
    func probe(center: Point) -> (frontmostIsEmptyApp: Bool, screenAnswers: Bool)
    func complete(_ root: AXElement) -> AXElement
}
