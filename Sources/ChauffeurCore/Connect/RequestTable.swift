import Foundation

/// One request the client may send: the method, the path template and the body attributes it may carry.
public struct RequestRow: Sendable {
    public let method: Method
    /// A template such as `/v1/builds/{id}`.
    public let path: String
    /// The first path segment after `/v1/`, such as `builds`.
    public let resource: String
    public let role: ConnectRole
    /// Body attributes the encoder may emit. Empty for GET.
    public let fields: [String]

    public init(method: Method, path: String, resource: String, role: ConnectRole, fields: [String]) {
        self.method = method
        self.path = path
        self.resource = resource
        self.role = role
        self.fields = fields
    }
}

/// The static table of every request chauffeur can send, and the list of what it refuses to.
public enum RequestTable {
    private static func get(_ path: String) -> RequestRow {
        let resource = path.dropFirst("/v1/".count).split(separator: "/").first.map(String.init) ?? ""
        return RequestRow(method: .get, path: path, resource: resource, role: .developer, fields: [])
    }

    public static let rows: [Operation.Kind: RequestRow] = [
        .probeUsers: get("/v1/users"),
        .probeCertificates: get("/v1/certificates"),
        .probeApps: get("/v1/apps"),
        .apps: get("/v1/apps"),
        .builds: get("/v1/builds"),
        .build: get("/v1/builds/{id}"),
        .buildBetaDetail: get("/v1/builds/{id}/buildBetaDetail"),
        .betaGroups: get("/v1/betaGroups"),
        .preReleaseVersions: get("/v1/preReleaseVersions"),
        .appStoreVersions: get("/v1/apps/{id}/appStoreVersions"),
        .appStoreVersion: get("/v1/appStoreVersions/{id}"),
        .appStoreVersionLocalizations: get("/v1/appStoreVersions/{id}/appStoreVersionLocalizations"),
        .reviewSubmissions: get("/v1/reviewSubmissions"),
        .reviewSubmission: get("/v1/reviewSubmissions/{id}"),
        .buildUpload: get("/v1/buildUploads/{id}"),
        .buildUploadFiles: get("/v1/buildUploads/{id}/buildUploadFiles"),
    ]

    /// Resources a PATCH may never target.
    public static let forbiddenPatch: Set<String> = [
        "users", "certificates", "bundleIds", "profiles", "webhooks", "betaTesters",
    ]

    public struct Denied: Sendable {
        public let text: String
        public let violates: @Sendable (RequestRow) -> Bool
    }

    /// What chauffeur will never do, in the order the capability sheet prints it.
    public static let denied: [Denied] = [
        Denied(text: "expire a build") {
            $0.resource == "builds" && $0.method != .get && $0.fields.contains("expired")
        },
        Denied(text: "cancel a submission") {
            $0.resource == "reviewSubmissions" && $0.method != .get && $0.fields.contains("canceled")
        },
        Denied(text: "remove a tester") {
            (($0.resource == "betaTesters" || $0.resource == "betaTesterUsages") && $0.method != .get)
                || $0.path.contains("/relationships/betaTesters")
        },
        Denied(text: "delete a webhook") { $0.resource == "webhooks" && $0.method != .get },
        Denied(text: "change pricing") {
            ($0.resource.hasPrefix("appPrice") || $0.resource.hasPrefix("appPricePoints")) && $0.method != .get
        },
    ]

    /// The texts of every deny entry that no row violates.
    public static func never() -> [String] {
        denied.filter { entry in !rows.values.contains(where: entry.violates) }.map(\.text)
    }

    public static func path(for op: Operation) -> String {
        var path = rows[op.kind]?.path ?? ""
        for (name, value) in op.pathParameters {
            path = path.replacingOccurrences(of: "{\(name)}", with: encode(value, pathAllowed))
        }
        return path
    }

    public static func pathAndQuery(for op: Operation) -> String {
        let query = op.query
        guard !query.isEmpty else { return path(for: op) }
        let pairs = query.map { "\($0.name)=\(encode($0.value, queryAllowed))" }
        return path(for: op) + "?" + pairs.joined(separator: "&")
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        return set
    }()

    private static func encode(_ value: String, _ allowed: CharacterSet) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
