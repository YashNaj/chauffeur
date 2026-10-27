import Foundation

/// `keys add`, `keys check`, `keys use`, `keys list` and `keys remove`. A key is probed before it is stored, and
/// only a key the probes accepted is stored. Nothing here renders the key, a token or the keychain comment.
public enum ConnectKeys {
    /// What the commands touch outside themselves. Tests swap each one for a fake.
    public struct Environment: Sendable {
        public var store: KeyStore
        public var presence: Presence
        public var transport: ConnectTransport
        public var readFile: @Sendable (URL) throws -> String
        public var now: @Sendable () -> Date

        public init(
            store: KeyStore, presence: Presence, transport: ConnectTransport,
            readFile: @escaping @Sendable (URL) throws -> String, now: @escaping @Sendable () -> Date
        ) {
            self.store = store
            self.presence = presence
            self.transport = transport
            self.readFile = readFile
            self.now = now
        }

        public static func live() -> Environment {
            Environment(
                store: KeychainStore(), presence: LocalPresence(), transport: URLSessionTransport(),
                readFile: { try String(contentsOf: $0, encoding: .utf8) }, now: Date.init)
        }
    }

    /// Reads and parses the key, refuses a stored id, probes, and stores the key only when the probes accept it.
    public static func add(
        file: String, issuer: String, keyID: String, role: ConnectRole, presence: Bool, cwd: URL, env: Environment
    ) throws -> Output {
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : cwd.appendingPathComponent(file)
        let pem: String
        do {
            pem = try env.readFile(url)
        } catch {
            throw ConnectError.badKeyFile("cannot read \(file): \(error.localizedDescription)")
        }
        let key = try ConnectKey(pem: pem, keyID: keyID, issuer: issuer)
        if try env.store.list().contains(where: { $0.keyID == keyID }) {
            throw ConnectError.duplicateKey(keyID)
        }
        let verdict = try Probe.run(ConnectClient(key: key, role: role, transport: env.transport, now: env.now))
        guard case .accepted(let apps) = verdict else {
            return Output(Probe.message(verdict), exit: 1)
        }
        let stored = StoredKey(
            keyID: keyID, issuer: issuer, role: role, apps: apps, added: timestamp(env.now()), presence: presence)
        try env.store.add(stored, pem: pem)
        let place =
            presence
            ? "in your login keychain, Touch ID to use"
            : "in your login keychain (no presence: any process running as you can read it)"
        let text = [
            CapabilitySheet.render(keyID: keyID, role: role, issuer: issuer, apps: apps),
            "stored key \(keyID) (\(role.title), \(apps.count) apps) \(place)",
            "hint: \(file) is still on disk; keep a copy somewhere safe, then delete it",
            #"note: a rebuilt chauffeur asks the keychain once ("Always Allow" remembers that build)"#,
        ].joined(separator: "\n")
        let data: JSON = .object([
            "keyID": .string(keyID), "role": .string(role.rawValue), "apps": JSON(apps), "presence": .bool(presence),
        ])
        return Output(text, data: data)
    }

    /// Loads the resolved key (the flag's, else the project pin's, else the only one), asking for presence when it
    /// was stored with it, and probes it again.
    public static func check(keyID: String?, cwd: URL, env: Environment) throws -> Output {
        let chosen = try resolve(flag: keyID, config: Target.connectKey(from: cwd), stored: env.store.list())
        let (key, stored) = try KeyLoader.load(keyID: chosen.keyID, store: env.store, presence: env.presence)
        let client = ConnectClient(key: key, role: stored.role, transport: env.transport, now: env.now)
        let verdict = try Probe.run(client)
        switch verdict {
        case .accepted(let apps):
            let sheet = CapabilitySheet.render(
                keyID: stored.keyID, role: stored.role, issuer: stored.issuer, apps: apps)
            return Output(sheet + "\nkey \(stored.keyID): ok (\(apps.count) apps)")
        case .refusedAdmin, .refusedCertificates:
            return Output(
                Probe.message(verdict) + "\nit is still stored: chauffeur keys remove \(stored.keyID)", exit: 1)
        case .unauthorized, .rateLimited:
            return Output(Probe.message(verdict), exit: 1)
        }
    }

    /// Pins a stored key for the project: `connectKey` in `cwd`'s `.chauffeur.json`, every other key kept.
    public static func use(keyID: String, cwd: URL, env: Environment) throws -> Output {
        let ids = try env.store.list().map(\.keyID)
        guard ids.contains(keyID) else { throw ConnectError.unknownKey(keyID, known: ids) }
        try Target.setConfig("connectKey", to: keyID, in: cwd)
        return Output("using key \(keyID) for \(cwd.path)")
    }

    /// The stored keys from their records alone: no key data is read and no issuer is shown.
    public static func list(cwd: URL, env: Environment) throws -> Output {
        let keys = try env.store.list()
        guard !keys.isEmpty else {
            return Output(
                "no keys stored (chauffeur keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role app-manager)",
                data: ["keys": []])
        }
        let pinned = Target.connectKey(from: cwd)
        let lines = keys.map { key in
            let parts = [
                key.keyID, key.role.title, "\(key.apps.count) apps", "added \(key.added.prefix(10))",
                key.presence ? "presence" : "no presence",
            ]
            return (parts + (key.keyID == pinned ? ["pinned"] : [])).joined(separator: " · ")
        }
        let rows: [JSON] = keys.map { key in
            .object([
                "keyID": .string(key.keyID), "role": .string(key.role.rawValue), "apps": JSON(key.apps),
                "added": .string(key.added), "presence": .bool(key.presence), "pinned": .bool(key.keyID == pinned),
            ])
        }
        return Output(lines.joined(separator: "\n"), data: ["keys": .array(rows)])
    }

    /// Deletes the key from the keychain. It stays valid at Apple until someone revokes it there.
    public static func remove(keyID: String, env: Environment) throws -> Output {
        try env.store.remove(keyID)
        return Output(
            "removed key \(keyID) from your login keychain. It is not revoked: revoke it in App Store Connect "
                + "(Users and Access ▸ Integrations) when it is no longer needed")
    }

    /// The flag's id, else the config's, else the only stored key.
    public static func resolve(flag: String?, config: String?, stored: [StoredKey]) throws -> StoredKey {
        let ids = stored.map(\.keyID)
        if let id = flag ?? config {
            guard let key = stored.first(where: { $0.keyID == id }) else {
                throw ConnectError.unknownKey(id, known: ids)
            }
            return key
        }
        guard stored.count == 1, let only = stored.first else { throw ConnectError.noKey(known: ids) }
        return only
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
