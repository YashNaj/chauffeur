import Foundation

/// Hosts whose requests are telemetry (analytics, crash reporting, attribution): they never make a tap PENDING
/// (M4b spec §4). One per line, so a PR can add one.
public enum Telemetry {
    public static let builtIn: [String] = [
        "app-measurement.com",
        "google-analytics.com",
        "firebaselogging-pa.googleapis.com",
        "firebaselogging.googleapis.com",
        "crashlytics.com",
        "crashlyticsreports-pa.googleapis.com",
        "sentry.io",
        "segment.io",
        "segment.com",
        "amplitude.com",
        "mixpanel.com",
        "appsflyer.com",
        "appsflyersdk.com",
        "adjust.com",
        "adjust.world",
        "branch.io",
        "datadoghq.com",
        "datadoghq.eu",
        "newrelic.com",
        "nr-data.net",
        "bugsnag.com",
        "instabug.com",
        "heapanalytics.com",
        "posthog.com",
        "fullstory.com",
        "logrocket.io",
        "lr-ingest.io",
        "hotjar.com",
        "rollbar.com",
        "flurry.com",
        "kochava.com",
        "singular.net",
    ]

    /// `extra` holds a project's entries: a domain suffix, optionally followed by a path prefix
    /// (`example.com/metrics`), matched against the path's shape. A path entry never matches an unknown path.
    public static func isTelemetry(host: String, path: String?, extra: [String]) -> Bool {
        let host = host.lowercased()
        let shaped = path.map(PathShape.shape)
        return (builtIn + extra).contains { entry in
            // Domains are case-insensitive; paths are not.
            let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let domain = parts[0].lowercased()
            guard host == domain || host.hasSuffix("." + domain) else { return false }
            guard parts.count == 2 else { return true }
            guard let shaped else { return false }
            let prefix = "/" + parts[1]
            return shaped == prefix || shaped.hasPrefix(prefix + "/")
        }
    }
}
