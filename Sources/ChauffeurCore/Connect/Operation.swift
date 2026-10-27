import Foundation

/// HTTP methods the client can send. There is no `delete` case: a DELETE can't be expressed.
public enum Method: String, Sendable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
}

/// Every request the client can send. Each case maps to one row of `RequestTable.rows`.
public enum Operation: Equatable, Sendable {
    case probeUsers
    case probeCertificates
    case probeApps
    case apps(bundleID: String?)
    case builds(appID: String, version: String?, buildNumber: String?)
    case build(id: String)
    case buildBetaDetail(buildID: String)
    case betaGroups(appID: String)
    case preReleaseVersions(appID: String)
    case appStoreVersions(appID: String)
    case appStoreVersion(id: String)
    case appStoreVersionLocalizations(versionID: String)
    case reviewSubmissions(appID: String)
    case reviewSubmission(id: String)
    case buildUpload(id: String)
    case buildUploadFiles(uploadID: String)

    /// One case per `Operation` case, same names, so `Kind.allCases` enumerates the table.
    public enum Kind: String, CaseIterable, Sendable {
        case probeUsers, probeCertificates, probeApps, apps, builds, build, buildBetaDetail
        case betaGroups, preReleaseVersions, appStoreVersions, appStoreVersion
        case appStoreVersionLocalizations, reviewSubmissions, reviewSubmission, buildUpload, buildUploadFiles
    }

    public var kind: Kind {
        switch self {
        case .probeUsers: .probeUsers
        case .probeCertificates: .probeCertificates
        case .probeApps: .probeApps
        case .apps: .apps
        case .builds: .builds
        case .build: .build
        case .buildBetaDetail: .buildBetaDetail
        case .betaGroups: .betaGroups
        case .preReleaseVersions: .preReleaseVersions
        case .appStoreVersions: .appStoreVersions
        case .appStoreVersion: .appStoreVersion
        case .appStoreVersionLocalizations: .appStoreVersionLocalizations
        case .reviewSubmissions: .reviewSubmissions
        case .reviewSubmission: .reviewSubmission
        case .buildUpload: .buildUpload
        case .buildUploadFiles: .buildUploadFiles
        }
    }

    /// Values for the `{id}` placeholder in the row's path template.
    public var pathParameters: [String: String] {
        switch self {
        case .probeUsers, .probeCertificates, .probeApps, .apps, .builds, .betaGroups, .preReleaseVersions,
            .reviewSubmissions:
            return [:]
        case .build(let id), .appStoreVersion(let id), .reviewSubmission(let id), .buildUpload(let id):
            return ["id": id]
        case .buildBetaDetail(let id): return ["id": id]
        case .appStoreVersions(let id): return ["id": id]
        case .appStoreVersionLocalizations(let id): return ["id": id]
        case .buildUploadFiles(let id): return ["id": id]
        }
    }

    /// Query pairs, sorted by name.
    public var query: [(name: String, value: String)] {
        var pairs: [(name: String, value: String)]
        switch self {
        case .probeUsers, .probeCertificates:
            pairs = [("limit", "1")]
        case .probeApps:
            pairs = [("limit", "200")]
        case .apps(let bundleID):
            pairs = [("limit", "200")]
            if let bundleID { pairs.append(("filter[bundleId]", bundleID)) }
        case .builds(let appID, let version, let buildNumber):
            pairs = [("filter[app]", appID), ("limit", "200"), ("sort", "-uploadedDate")]
            if let version { pairs.append(("filter[preReleaseVersion.version]", version)) }
            if let buildNumber { pairs.append(("filter[version]", buildNumber)) }
        case .betaGroups(let appID), .preReleaseVersions(let appID), .reviewSubmissions(let appID):
            pairs = [("filter[app]", appID), ("limit", "200")]
        case .appStoreVersions, .appStoreVersionLocalizations, .buildUploadFiles:
            pairs = [("limit", "200")]
        case .build, .buildBetaDetail, .appStoreVersion, .reviewSubmission, .buildUpload:
            pairs = []
        }
        return pairs.sorted { $0.name < $1.name }
    }
}
