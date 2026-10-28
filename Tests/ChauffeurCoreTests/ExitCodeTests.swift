import Testing

@testable import ChauffeurCore

@Suite struct ExitCodeTests {
    @Test func usageLineIsBuiltFromTheCodes() {
        #expect(Usage.text.contains(ExitCode.allCases.map(\.line).joined(separator: " · ")))
    }
    @Test func oneMappingForEveryErrorKind() {
        #expect(Output.failure(ChauffeurError.usage("usage: x")).exit == ExitCode.usage.rawValue)
        #expect(Output.failure(ChauffeurError.notBooted("U")).exit == 1)
        #expect(Output.failure(RefError.stale("e4", name: "x")).exit == 1)
        #expect(Output.failure(ConnectError.noKey(known: [])).exit == 1)
        #expect(Output.failure(MCPToolError.invalid("act tap needs target")).text == "act tap needs target")
    }
}
