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
    @Test func noPostOnTheForbiddenResources() {
        #expect(
            RequestTable.forbiddenPost == [
                "certificates", "bundleIds", "profiles", "userInvitations", "webhooks", "inAppPurchases",
                "subscriptions", "appPriceSchedules", "appAvailabilities",
            ])
        for (kind, row) in RequestTable.rows where row.method == .post {
            #expect(!RequestTable.forbiddenPost.contains(row.resource), "\(kind)")
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
                "expire a build", "cancel a submission", "remove a tester",
                "delete or revoke a certificate, identifier or profile", "invite or remove a user",
                "change pricing or availability", "touch in-app purchases", "manage webhooks",
            ])
        #expect(RequestTable.never(in: RequestTable.rows) == RequestTable.denied.map(\.text))
    }
    @Test func everyDenyEntryCatchesItsViolation() {
        func row(_ method: Method, _ resource: String, _ fields: [String] = []) -> RequestRow {
            RequestRow(
                method: method, path: "/v1/\(resource)/{id}", resource: resource, role: .appManager, fields: fields)
        }
        let cases: [(violating: RequestRow, benign: RequestRow)] = [
            (row(.patch, "builds", ["expired"]), row(.get, "builds")),
            (row(.patch, "reviewSubmissions", ["canceled"]), row(.get, "reviewSubmissions")),
            (row(.post, "betaTesters"), row(.get, "betaTesters")),
            (row(.post, "certificates"), row(.get, "certificates")),
            (row(.patch, "userInvitations"), row(.get, "userInvitations")),
            (row(.post, "appAvailabilities"), row(.get, "appAvailabilities")),
            (row(.post, "subscriptionGroups"), row(.get, "subscriptionGroups")),
            (row(.post, "webhooks"), row(.get, "webhooks")),
        ]
        // Every resource each entry names is caught, and a GET on it never is.
        let named: [(entry: Int, resources: [String])] = [
            (3, ["certificates", "bundleIds", "profiles"]), (4, ["users", "userInvitations"]),
            (5, ["appPriceSchedules", "appPrices", "appAvailabilities", "appAvailabilityV2"]),
            (6, ["inAppPurchases", "inAppPurchasesV2", "subscriptions", "subscriptionGroups"]), (7, ["webhooks"]),
        ]
        for (index, resources) in named {
            for resource in resources {
                #expect(RequestTable.denied[index].violates(row(.post, resource)), "\(resource)")
                #expect(RequestTable.denied[index].violates(row(.put, resource)), "\(resource)")
                #expect(!RequestTable.denied[index].violates(row(.get, resource)), "\(resource)")
            }
        }
        #expect(cases.count == RequestTable.denied.count)
        let all = RequestTable.denied.map(\.text)
        for (entry, pair) in zip(RequestTable.denied, cases) {
            #expect(entry.violates(pair.violating), "\(entry.text)")
            #expect(!entry.violates(pair.benign), "\(entry.text)")
            var rows = RequestTable.rows
            rows[.build] = pair.violating
            #expect(RequestTable.never(in: rows) == all.filter { $0 != entry.text }, "\(entry.text)")
        }
    }
    @Test func pathsAndQueries() {
        #expect(
            RequestTable.pathAndQuery(for: .probeFinance(month: "2026-09"))
                == "/v1/financeReports?filter[regionCode]=US&filter[reportDate]=2026-09&filter[reportType]=FINANCIAL"
                + "&filter[vendorNumber]=0")
        #expect(RequestTable.rows[.probeFinance]?.accept == "application/a-gzip")
        #expect(RequestTable.rows[.probeFinance]?.resource == "financeReports")
        #expect(RequestTable.rows[.probeApps]?.accept == "application/json")
        #expect(RequestTable.pathAndQuery(for: .build(id: "b1")) == "/v1/builds/b1")
        #expect(
            RequestTable.pathAndQuery(for: .apps(bundleID: "dev.chauffeur.fixture"))
                == "/v1/apps?filter[bundleId]=dev.chauffeur.fixture&limit=200")
        #expect(
            RequestTable.pathAndQuery(for: .builds(appID: "a1", version: "1.3.0", buildNumber: nil))
                == "/v1/builds?filter[app]=a1&filter[preReleaseVersion.version]=1.3.0&limit=200&sort=-uploadedDate")
        #expect(
            RequestTable.path(for: .buildUploadFiles(uploadID: "u/1")) == "/v1/buildUploads/u%2F1/buildUploadFiles")
        #expect(
            RequestTable.path(for: .appStoreVersions(appID: "..")) == "/v1/apps/%2E%2E/appStoreVersions")
        #expect(RequestTable.path(for: .build(id: "a.b")) == "/v1/builds/a%2Eb")
    }
}
