import Testing

@testable import ChauffeurCore

/// Every report shape, rendered as text and as JSON, pinned byte for byte.
@Suite struct GoldenReportTests {
    @Test(arguments: ReportCases.all.map(\.name)) func renders(_ name: String) throws {
        let report = try #require(ReportCases.all.first { $0.name == name }).report
        Golden.check("reports/\(name).txt", report.render())
        Golden.check("reports/\(name).json", report.json.line())
    }
}
