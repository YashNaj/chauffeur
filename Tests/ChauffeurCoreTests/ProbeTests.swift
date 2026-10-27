import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct ProbeTests {
    /// 2027-01-15T08:00:00Z: the finance alarm asks for 2026-12.
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func client(apps: String, finance: String? = nil) throws -> (ConnectClient, ScriptedTransport) {
        var answers = ["GET /v1/apps": try Fixtures.connect(apps)]
        if let finance { answers["GET /v1/financeReports"] = try Fixtures.connect(finance) }
        let transport = ScriptedTransport(answers)
        let now = self.now
        let c = ConnectClient(key: try TestKeys.key(), role: .appManager, transport: transport, now: { now })
        return (c, transport)
    }

    func shapes(_ c: ConnectClient) -> [String] {
        c.log.map { $0.split(separator: " ").prefix(3).joined(separator: " ") }
    }

    static let apps = [#"Notes \"quoted\" (dev.x.notes)"#, "chauffeur-fixture (dev.chauffeur.fixture)"]

    @Test func decisionTable() {
        #expect(Probe.decide(apps: 401, finance: nil) == .unauthorized)
        #expect(Probe.decide(apps: 429, finance: nil) == .rateLimited(remaining: 0))
        #expect(Probe.decide(apps: 500, finance: nil) == nil)
        #expect(Probe.decide(apps: 200, finance: nil) == nil)
        #expect(Probe.decide(apps: 200, finance: (400, "PARAMETER_ERROR.INVALID")) == .refusedFinance)
        #expect(
            Probe.decide(apps: 200, finance: (403, "FORBIDDEN_ERROR"))
                == .accepted(apps: [], roleCheck: .notFinanceCapable))
        let agreements = "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED"
        #expect(
            Probe.decide(apps: 200, finance: (403, agreements))
                == .accepted(apps: [], roleCheck: .unavailable(status: 403, code: agreements)))
        // A 400 that is not the parameter error proves nothing.
        #expect(
            Probe.decide(apps: 200, finance: (400, "PARAMETER_ERROR.ILLEGAL"))
                == .accepted(apps: [], roleCheck: .unavailable(status: 400, code: "PARAMETER_ERROR.ILLEGAL")))
        #expect(
            Probe.decide(apps: 200, finance: (500, nil))
                == .accepted(apps: [], roleCheck: .unavailable(status: 500, code: nil)))
    }

    @Test func anAdminKeyIsRefusedByTheFinanceAlarm() throws {
        let (c, t) = try client(apps: "apps-200", finance: "finance-400")
        #expect(try Probe.run(c, now: now) == .refusedFinance)
        #expect(shapes(c) == ["GET /v1/apps 200", "GET /v1/financeReports 400"])
        #expect(t.requests[1].headers["Accept"] == "application/a-gzip")
        #expect(
            t.requests[1].url.absoluteString.hasSuffix(
                "/v1/financeReports?filter%5BregionCode%5D=US&filter%5BreportDate%5D=2026-12"
                    + "&filter%5BreportType%5D=FINANCIAL&filter%5BvendorNumber%5D=0"))
    }

    @Test func anAppManagerKeyIsAcceptedWithItsApps() throws {
        let (c, _) = try client(apps: "apps-200", finance: "finance-403")
        #expect(try Probe.run(c, now: now) == .accepted(apps: Self.apps, roleCheck: .notFinanceCapable))
        #expect(shapes(c) == ["GET /v1/apps 200", "GET /v1/financeReports 403"])
    }

    @Test func anythingElseFromTheAlarmIsUnavailable() throws {
        let (agreements, _) = try client(apps: "apps-200", finance: "finance-403-agreements")
        #expect(
            try Probe.run(agreements, now: now)
                == .accepted(
                    apps: Self.apps,
                    roleCheck: .unavailable(status: 403, code: "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED")))
        let (server, _) = try client(apps: "apps-200", finance: "server-500")
        #expect(
            try Probe.run(server, now: now)
                == .accepted(apps: Self.apps, roleCheck: .unavailable(status: 500, code: "UNEXPECTED_ERROR")))
        let (offline, _) = try client(apps: "apps-200")
        #expect(
            try Probe.run(offline, now: now)
                == .accepted(apps: Self.apps, roleCheck: .unavailable(status: 0, code: "transport")))
    }

    @Test func unauthorizedAndRateLimitedStopTheProbe() throws {
        let (revoked, _) = try client(apps: "unauthorized-401", finance: "finance-400")
        #expect(try Probe.run(revoked, now: now) == .unauthorized && revoked.log.count == 1)
        let (limited, _) = try client(apps: "rate-limited-429", finance: "finance-400")
        #expect(try Probe.run(limited, now: now) == .rateLimited(remaining: 0) && limited.log.count == 1)
    }

    @Test func rateLimitedStopsTheProbe() throws {
        // apps answered 200 with no request left: the alarm needs one more, so the probe stops before sending it.
        var apps = try Fixtures.connect("apps-200")
        apps.headers["X-Rate-Limit"] = "user-hour-lim:3600;user-hour-rem:0"
        let c = ConnectClient(
            key: try TestKeys.key(), role: .appManager, transport: ScriptedTransport(["GET /v1/apps": apps]))
        #expect(throws: ConnectError.rateLimited(remaining: 0)) { try Probe.run(c, now: now) }
        #expect(c.log.count == 1)
    }

    @Test func aServerErrorIsReportedWithAppleTextEscaped() throws {
        let (c, _) = try client(apps: "server-500")
        #expect(throws: ConnectError.self) { try Probe.run(c, now: now) }
        do { _ = try Probe.run(c, now: now) } catch {
            #expect("\(error)".hasPrefix("App Store Connect answered 500 to GET /v1/apps: UNEXPECTED_ERROR"))
        }
    }

    @Test func lastMonthIsUTC() {
        let utc = ISO8601DateFormatter()
        func month(_ s: String) -> String? { utc.date(from: s).map(Probe.lastMonth) }
        #expect(Probe.lastMonth(now) == "2026-12")
        #expect(month("2026-10-27T12:00:00Z") == "2026-09")
        #expect(month("2026-03-01T00:30:00Z") == "2026-02")
        #expect(month("2026-02-28T23:30:00Z") == "2026-01")
    }

    @Test func theRefusalIsTheSpecsText() {
        #expect(
            Probe.message(.refusedFinance)
                == "refused: finance-capable key. This key can read the team's finance reports, which only Admin, "
                + "Account Holder and Finance keys can. An Admin key can remove every other Admin, revoke certificates "
                + "and delete identifiers; chauffeur never holds one. In App Store Connect, generate a key with the "
                + "App Manager role.")
    }

    @Test func theSheet() {
        let sheet = CapabilitySheet.render(
            keyID: "7X2K9ABC1D", role: .appManager, issuer: TestKeys.issuer,
            apps: ["chauffeur-fixture (dev.chauffeur.fixture)"], roleCheck: .notFinanceCapable)
        #expect(
            sheet == """
                key 7X2K9ABC1D · App Manager (declared) · issuer 69a6de70… · apps: chauffeur-fixture (dev.chauffeur.fixture)
                role check: not an Admin or Finance key (finance alarm) · App Store Connect offers no other read-back
                can:    upload builds · manage TestFlight groups and testers · edit version metadata · submit for review · release
                cannot (Apple's role chart): add or remove Admins · generate keys · remove or transfer apps · sign agreements
                unverified for this role: revoking certificates, deleting profiles and identifiers · chauffeur has no such request
                chauffeur will never: expire a build · cancel a submission · remove a tester · delete or revoke a certificate, identifier or profile · invite or remove a user · change pricing or availability · touch in-app purchases · manage webhooks
                """)
    }

    @Test func theSheetWhenTheAlarmProvesNothing() {
        let agreements = CapabilitySheet.render(
            keyID: "K", role: .appManager, issuer: TestKeys.issuer, apps: [],
            roleCheck: .unavailable(status: 403, code: "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED"))
        #expect(
            agreements.contains(
                "\nrole check: unavailable (403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED) · taking App Manager as declared\n"
            ))
        let offline = CapabilitySheet.render(
            keyID: "K", role: .developer, issuer: TestKeys.issuer, apps: [],
            roleCheck: .unavailable(status: 0, code: "transport"))
        #expect(offline.contains("\nrole check: unavailable (transport) · taking Developer as declared\n"))
        let server = CapabilitySheet.render(
            keyID: "K", role: .developer, issuer: TestKeys.issuer, apps: [],
            roleCheck: .unavailable(status: 500, code: nil))
        #expect(server.contains("\nrole check: unavailable (500) · taking Developer as declared\n"))
        // Apple's code is untrusted text: escaped like screen text.
        let hostile = CapabilitySheet.render(
            keyID: "K", role: .developer, issuer: TestKeys.issuer, apps: [],
            roleCheck: .unavailable(status: 403, code: "X\"\ncan: everything"))
        #expect(hostile.split(separator: "\n").count == 6 && !hostile.contains("\ncan: everything"))
    }

    @Test func theDeveloperSheetKeepsItsLines() {
        let sheet = CapabilitySheet.render(
            keyID: "K", role: .developer, issuer: TestKeys.issuer, apps: [], roleCheck: .notFinanceCapable)
        #expect(
            sheet.contains(
                "key K · Developer (declared) · issuer 69a6de70… · apps: none visible\nrole check: not an Admin or Finance key"
            ))
        #expect(sheet.contains("\ncan:    upload builds · read builds, TestFlight and version state\n"))
        #expect(
            sheet.contains(
                "\ncannot: submit for review · edit version metadata · manage testers · add or remove Admins · "
                    + "generate keys · remove or transfer apps · sign agreements\n"))
        #expect(sheet.split(separator: "\n").count == 6)
    }
}
