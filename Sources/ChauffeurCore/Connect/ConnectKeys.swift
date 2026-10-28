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
        /// The running build's signature. `add` and `check` refuse to run from a build that isn't hardened.
        public var identity: BuildIdentity

        public init(
            store: KeyStore, presence: Presence, transport: ConnectTransport,
            readFile: @escaping @Sendable (URL) throws -> String, now: @escaping @Sendable () -> Date,
            identity: BuildIdentity
        ) {
            self.store = store
            self.presence = presence
            self.transport = transport
            self.readFile = readFile
            self.now = now
            self.identity = identity
        }

        public static func live() -> Environment {
            Environment(
                store: KeychainStore(), presence: LocalPresence(), transport: URLSessionTransport(),
                readFile: { try String(contentsOf: $0, encoding: .utf8) }, now: Date.init,
                identity: LiveBuildIdentity())
        }
    }

    public static let usage =
        "usage: chauffeur keys add <AuthKey.p8> --issuer <uuid> --key-id <id> --role developer|app-manager "
        + "[--no-presence] · keys list · keys check [<key-id>] · keys remove <key-id> · keys use <key-id>"

    /// Parses `keys <subcommand> …` and runs it. Nothing here reaches the daemon.
    public static func handle(_ argv: [String], cwd: URL, env: Environment) throws -> Output {
        var a = try Args(
            argv, flags: ["--no-presence"], options: ["--issuer", "--key-id", "--role"], usage: usage)
        let subcommand = a.next()
        if subcommand != "add", !a.options.isEmpty || !a.flags.isEmpty {
            throw ChauffeurError.usage("--issuer, --key-id, --role and --no-presence belong to keys add\n" + usage)
        }
        switch subcommand {
        case "add":
            guard let file = a.next() else { throw ChauffeurError.usage(usage) }
            try a.done()
            func required(_ name: String) throws -> String {
                guard let value = a.option(name) else { throw ChauffeurError.usage("\(name) is required\n" + usage) }
                return value
            }
            let issuer = try required("--issuer")
            let keyID = try required("--key-id")
            guard let role = ConnectRole(flag: try required("--role")) else {
                throw ChauffeurError.usage("--role must be developer or app-manager\n" + usage)
            }
            return try add(
                file: file, issuer: issuer, keyID: keyID, role: role, presence: !a.flag("--no-presence"), cwd: cwd,
                env: env)
        case "list":
            try a.done()
            return try list(cwd: cwd, env: env)
        case "check":
            let keyID = a.next()
            try a.done()
            return try check(keyID: keyID, cwd: cwd, env: env)
        case "remove":
            guard let keyID = a.next() else { throw ChauffeurError.usage(usage) }
            try a.done()
            return try remove(keyID: keyID, env: env)
        case "use":
            guard let keyID = a.next() else { throw ChauffeurError.usage(usage) }
            try a.done()
            return try use(keyID: keyID, cwd: cwd, env: env)
        default:
            throw ChauffeurError.usage(usage)
        }
    }

    /// Reads and parses the key, refuses a stored id, probes, and stores the key only when the probes accept it.
    public static func add(
        file: String, issuer: String, keyID: String, role: ConnectRole, presence: Bool, cwd: URL, env: Environment
    ) throws -> Output {
        try requireHardened(env)
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
        let client = ConnectClient(key: key, role: role, transport: env.transport, now: env.now)
        let verdict = try Probe.run(client, now: env.now())
        guard case .accepted(let apps, let roleCheck) = verdict else {
            return Output(Probe.message(verdict), exit: .error)
        }
        let stored = StoredKey(
            keyID: keyID, issuer: issuer, role: role, apps: apps, added: timestamp(env.now()), presence: presence)
        try env.store.add(stored, pem: pem)
        let place =
            presence
            ? "in your login keychain, Touch ID to use"
            : "in your login keychain (no presence: any process running as you can read it)"
        let text = [
            CapabilitySheet.render(keyID: keyID, role: role, issuer: issuer, apps: apps, roleCheck: roleCheck),
            "stored key \(keyID) (\(role.title), \(apps.count) apps) \(place)",
            "hint: \(file) is still on disk; keep a copy somewhere safe, then delete it",
            #"note: a rebuilt chauffeur asks the keychain once ("Always Allow" remembers that build)"#,
        ].joined(separator: "\n")
        let data: JSON = .object([
            "keyID": .string(keyID), "role": .string(role.rawValue), "apps": JSON(apps), "presence": .bool(presence),
            "roleCheck": .string(name(roleCheck)),
        ])
        return Output(text, data: data)
    }

    /// Loads the resolved key (the flag's, else the project pin's, else the only one), asking for presence when it
    /// was stored with it, and probes it again.
    public static func check(keyID: String?, cwd: URL, env: Environment) throws -> Output {
        try requireHardened(env)
        let chosen = try resolve(flag: keyID, config: Target.connectKey(from: cwd), stored: env.store.list())
        let (key, stored) = try KeyLoader.load(keyID: chosen.keyID, store: env.store, presence: env.presence)
        let client = ConnectClient(key: key, role: stored.role, transport: env.transport, now: env.now)
        let verdict = try Probe.run(client, now: env.now())
        switch verdict {
        case .accepted(let apps, let roleCheck):
            let sheet = CapabilitySheet.render(
                keyID: stored.keyID, role: stored.role, issuer: stored.issuer, apps: apps, roleCheck: roleCheck)
            let data: JSON = .object([
                "keyID": .string(stored.keyID), "role": .string(stored.role.rawValue), "apps": JSON(apps),
                "roleCheck": .string(name(roleCheck)),
            ])
            return Output(sheet + "\nkey \(stored.keyID): ok (\(apps.count) apps)", data: data)
        case .refusedFinance:
            return Output(
                Probe.message(verdict) + "\nit is still stored: chauffeur keys remove \(stored.keyID)", exit: .error)
        case .unauthorized, .rateLimited:
            return Output(Probe.message(verdict), exit: .error)
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

    /// Refuses before any store or network call when this build could be injected into or debugged.
    private static func requireHardened(_ env: Environment) throws {
        guard env.identity.hardenedRuntime && !env.identity.debuggable else { throw ConnectError.unhardenedBuild }
    }

    /// The `roleCheck` value in `--json` output. Apple's code stays out of it: it is untrusted text.
    private static func name(_ roleCheck: RoleCheck) -> String {
        switch roleCheck {
        case .notFinanceCapable: return "not-finance-capable"
        case .unavailable: return "unavailable"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
