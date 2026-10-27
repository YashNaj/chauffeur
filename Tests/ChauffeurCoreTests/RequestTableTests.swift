import Testing

@testable import ChauffeurCore

@Suite struct RequestTableTests {
    @Test func everyOperationHasARow() {
        for kind in Operation.Kind.allCases { #expect(RequestTable.rows[kind] != nil, "\(kind)") }
        #expect(RequestTable.rows.count == Operation.Kind.allCases.count)
    }
    @Test func thereIsNoDelete() {
        #expect(!Method.allCases.map(\.rawValue).contains("DELETE"))
    }
    @Test func noPatchOnTheForbiddenResources() {
        for (kind, row) in RequestTable.rows where row.method == .patch {
            #expect(!RequestTable.forbiddenPatch.contains(row.resource), "\(kind)")
        }
    }
    @Test func buildsAndSubmissionsCannotExpireOrCancel() {
        for row in RequestTable.rows.values where row.resource == "builds" { #expect(!row.fields.contains("expired")) }
        for row in RequestTable.rows.values where row.resource == "reviewSubmissions" {
            #expect(!row.fields.contains("canceled"))
        }
    }
    @Test func m5aIsReadsOnly() {
        for (kind, row) in RequestTable.rows { #expect(row.method == .get && row.fields.isEmpty, "\(kind)") }
    }
    @Test func theNeverLineIsTheWholeDenyList() {
        #expect(
            RequestTable.never() == [
                "expire a build", "cancel a submission", "remove a tester", "delete a webhook", "change pricing",
            ])
        let expiring = RequestRow(
            method: .patch, path: "/v1/builds/{id}", resource: "builds", role: .appManager, fields: ["expired"])
        #expect(RequestTable.denied[0].violates(expiring))
    }
    @Test func pathsAndQueries() {
        #expect(RequestTable.pathAndQuery(for: .probeUsers) == "/v1/users?limit=1")
        #expect(RequestTable.pathAndQuery(for: .build(id: "b1")) == "/v1/builds/b1")
        #expect(
            RequestTable.pathAndQuery(for: .apps(bundleID: "dev.chauffeur.fixture"))
                == "/v1/apps?filter[bundleId]=dev.chauffeur.fixture&limit=200")
        #expect(
            RequestTable.pathAndQuery(for: .builds(appID: "a1", version: "1.3.0", buildNumber: nil))
                == "/v1/builds?filter[app]=a1&filter[preReleaseVersion.version]=1.3.0&limit=200&sort=-uploadedDate")
        #expect(
            RequestTable.path(for: .buildUploadFiles(uploadID: "u/1")) == "/v1/buildUploads/u%2F1/buildUploadFiles")
    }
}
