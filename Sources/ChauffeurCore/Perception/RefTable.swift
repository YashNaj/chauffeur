/// Session-wide mapping between element identities and short refs (spec §5.3).
/// The same identity keeps the same ref for the life of the daemon.
public struct RefTable: Sendable {
    private var byIdentity: [Identity: String] = [:]
    private var byRef: [String: Identity] = [:]
    private var names: [String: String] = [:]

    public init() {}

    /// The ref for `identity`; `name` is remembered as what the agent last saw the element called.
    public mutating func ref(for identity: Identity, name: String? = nil) -> String {
        let ref: String
        if let known = byIdentity[identity] {
            ref = known
        } else {
            ref = "e\(byIdentity.count + 1)"
            byIdentity[identity] = ref
            byRef[ref] = identity
        }
        if let name { names[ref] = name }
        return ref
    }

    public func identity(for ref: String) -> Identity? { byRef[ref] }

    /// The element's label when its ref was last shown. Its identity key can be an accessibility identifier, which
    /// the agent never saw (M1 review minor).
    public func name(for ref: String) -> String? { names[ref] }
}
