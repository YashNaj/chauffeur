import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ProbeTests {
    func client(users: String, certificates: String? = nil, apps: String? = nil) throws -> ConnectClient {
        var answers = ["GET /v1/users": try Fixtures.connect(users)]
        if let certificates { answers["GET /v1/certificates"] = try Fixtures.connect(certificates) }
        if let apps { answers["GET /v1/apps"] = try Fixtures.connect(apps) }
        return ConnectClient(key: try TestKeys.key(), role: .appManager, transport: ScriptedTransport(answers))
    }
    @Test func decisionTable() {
        #expect(Probe.decide(users: 200, certificates: nil, apps: nil) == .refusedAdmin)
        #expect(Probe.decide(users: 403, certificates: 200, apps: nil) == .refusedCertificates)
        #expect(Probe.decide(users: 403, certificates: 403, apps: ["A (a)"]) == .accepted(apps: ["A (a)"]))
        #expect(Probe.decide(users: 401, certificates: nil, apps: nil) == .unauthorized)
        #expect(Probe.decide(users: 429, certificates: nil, apps: nil) == .rateLimited(remaining: 0))
        #expect(Probe.decide(users: 500, certificates: nil, apps: nil) == nil)
    }
    @Test func anAdminKeyIsRefusedAfterOneRequest() throws {
        let c = try client(users: "users-200")
        #expect(try Probe.run(c) == .refusedAdmin && c.log.count == 1)
    }
    @Test func aCertificatesKeyIsRefused() throws {
        #expect(try Probe.run(try client(users: "users-403", certificates: "certificates-200")) == .refusedCertificates)
    }
    @Test func anAppManagerWithoutTheToggleIsAcceptedWithItsApps() throws {
        let c = try client(users: "users-403", certificates: "certificates-403", apps: "apps-200")
        #expect(
            try Probe.run(c)
                == .accepted(apps: ["Fixture (dev.chauffeur.fixture)", #"Notes \"quoted\" (dev.x.notes)"#]))
        #expect(
            c.log.map { $0.split(separator: " ").prefix(3).joined(separator: " ") } == [
                "GET /v1/users 403", "GET /v1/certificates 403", "GET /v1/apps 200",
            ])
    }
    @Test func unauthorizedAndRateLimitedStopTheProbe() throws {
        #expect(try Probe.run(try client(users: "unauthorized-401")) == .unauthorized)
        #expect(try Probe.run(try client(users: "rate-limited-429")) == .rateLimited(remaining: 0))
    }
    @Test func rateLimitedStopsTheProbe() throws {
        // users answered 403 with one request left: the probe needs two more, so it stops before sending them.
        var users = try Fixtures.connect("users-403")
        users.headers["X-Rate-Limit"] = "user-hour-lim:3600;user-hour-rem:1"
        let c = ConnectClient(
            key: try TestKeys.key(), role: .appManager, transport: ScriptedTransport(["GET /v1/users": users]))
        #expect(throws: ConnectError.rateLimited(remaining: 1)) { try Probe.run(c) }
    }
    @Test func aServerErrorIsReportedWithAppleTextEscaped() throws {
        let c = try client(users: "server-500")
        #expect(throws: ConnectError.self) { try Probe.run(c) }
        do { _ = try Probe.run(c) } catch {
            #expect("\(error)".hasPrefix("App Store Connect answered 500 to GET /v1/users: UNEXPECTED_ERROR"))
        }
    }
    @Test func theSheet() {
        let sheet = CapabilitySheet.render(
            keyID: "7X2K9ABC1D", role: .appManager, issuer: TestKeys.issuer, apps: ["Fixture (dev.chauffeur.fixture)"])
        #expect(
            sheet == """
                key 7X2K9ABC1D · App Manager · issuer 69a6de70… · apps: Fixture (dev.chauffeur.fixture)
                can:    upload builds · manage TestFlight groups and testers · edit version metadata · submit for review · release
                cannot: touch certificates, identifiers or profiles · add or remove people · change roles · delete apps · create keys
                chauffeur will never: expire a build · cancel a submission · remove a tester · delete a webhook · change pricing
                """)
        #expect(
            CapabilitySheet.render(keyID: "K", role: .developer, issuer: TestKeys.issuer, apps: []).contains(
                "apps: none visible\ncan:    upload builds · read builds, TestFlight and version state\n"))
        #expect(Probe.message(.refusedAdmin).hasPrefix("refused: Admin key."))
    }
}
