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
    /// The `Accept` header the request carries.
    public let accept: String

    public init(
        method: Method, path: String, resource: String, role: ConnectRole, fields: [String],
        accept: String = "application/json"
    ) {
        self.method = method
        self.path = path
        self.resource = resource
        self.role = role
        self.fields = fields
        self.accept = accept
    }
}

/// The static table of every request chauffeur can send, and the list of what it refuses to.
public enum RequestTable {
    private static func get(_ path: String, accept: String = "application/json") -> RequestRow {
        let resource = path.dropFirst("/v1/".count).split(separator: "/").first.map(String.init) ?? ""
        return RequestRow(method: .get, path: path, resource: resource, role: .developer, fields: [], accept: accept)
    }

    public static let rows: [Operation.Kind: RequestRow] = [
        .probeApps: get("/v1/apps"),
        // Finance reports are served gzipped, so the alarm asks for what a real report request would.
        .probeFinance: get("/v1/financeReports", accept: "application/a-gzip"),
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

    /// Resources a POST may never target.
    public static let forbiddenPost: Set<String> = [
        "certificates", "bundleIds", "profiles", "userInvitations", "webhooks", "inAppPurchases", "subscriptions",
        "appPriceSchedules", "appAvailabilities",
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
        Denied(text: "delete or revoke a certificate, identifier or profile") {
            ["certificates", "bundleIds", "profiles"].contains($0.resource) && $0.method != .get
        },
        Denied(text: "invite or remove a user") {
            ["users", "userInvitations"].contains($0.resource) && $0.method != .get
        },
        Denied(text: "change pricing or availability") {
            ($0.resource.hasPrefix("appPrice") || $0.resource.hasPrefix("appAvailabilit")) && $0.method != .get
        },
        Denied(text: "touch in-app purchases") {
            ($0.resource.hasPrefix("inAppPurchase") || $0.resource.hasPrefix("subscription")) && $0.method != .get
        },
        Denied(text: "manage webhooks") { $0.resource == "webhooks" && $0.method != .get },
    ]

    /// The texts of every deny entry that no row violates.
    public static func never() -> [String] { never(in: rows) }

    static func never(in rows: [Operation.Kind: RequestRow]) -> [String] {
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
        set.remove(charactersIn: "/.")
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
