import Testing

@testable import ChauffeurCore

/// M4b spec §4: telemetry never turns a dead button into PENDING.
@Suite struct TelemetryTests {
    @Test func builtInHostsMatchBySuffix() {
        #expect(Telemetry.isTelemetry(host: "app-measurement.com", path: "/a", extra: []))
        #expect(Telemetry.isTelemetry(host: "o123.ingest.sentry.io", path: nil, extra: []))
        #expect(Telemetry.isTelemetry(host: "API.MIXPANEL.COM", path: "/track", extra: []))
        #expect(!Telemetry.isTelemetry(host: "api.example.com", path: "/login", extra: []))
    }

    @Test func suffixesMatchWholeLabels() {
        #expect(!Telemetry.isTelemetry(host: "notsentry.io", path: nil, extra: []))
        #expect(!Telemetry.isTelemetry(host: "sentry.io.example.com", path: nil, extra: []))
    }

    @Test func projectEntriesAddHostsAndPathPrefixes() {
        let extra = ["events.example.com", "example.com/metrics"]
        #expect(Telemetry.isTelemetry(host: "events.example.com", path: "/x", extra: extra))
        #expect(Telemetry.isTelemetry(host: "api.example.com", path: "/metrics/batch?k=1", extra: extra))
        #expect(!Telemetry.isTelemetry(host: "api.example.com", path: "/login", extra: extra))
    }

    @Test func pathPrefixesMatchWholeSegments() {
        #expect(!Telemetry.isTelemetry(host: "example.com", path: "/metricsfoo", extra: ["example.com/metrics"]))
        #expect(Telemetry.isTelemetry(host: "example.com", path: "/metrics", extra: ["example.com/metrics"]))
    }

    @Test func aPathEntryNeedsAKnownPath() {
        #expect(!Telemetry.isTelemetry(host: "example.com", path: nil, extra: ["example.com/metrics"]))
    }

    @Test func pathEntriesMatchTheShape() {
        #expect(
            Telemetry.isTelemetry(host: "example.com", path: "/u/8812/events", extra: ["example.com/u/{id}/events"]))
    }

    @Test func theBuiltInListIsLowercaseAndUnique() {
        #expect(Telemetry.builtIn.count >= 25)
        #expect(Set(Telemetry.builtIn).count == Telemetry.builtIn.count)
        #expect(Telemetry.builtIn.allSatisfy { $0 == $0.lowercased() && !$0.contains("/") })
    }
}
