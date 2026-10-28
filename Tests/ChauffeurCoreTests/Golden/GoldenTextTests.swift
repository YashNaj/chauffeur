import Testing

@testable import ChauffeurCore

/// The text an agent reads, pinned byte for byte so a refactor cannot change it unseen.
@Suite struct GoldenTextTests {
    @Test func usage() { Golden.check("usage.txt", Usage.text) }
    @Test func skill() { Golden.check("skill.md", Skill.skillMarkdown) }
    @Test func agentsSection() { Golden.check("agents.md", Skill.agentsSection) }
    @Test @MainActor func mcpInstructions() { Golden.check("mcp-instructions.txt", MCPServer.instructions) }
    /// `JSON.line()` already sorts keys, so the tool list renders the same every run.
    @Test func mcpTools() { Golden.check("mcp-tools.json", JSON.array(MCPTools.definitions).line()) }
}
