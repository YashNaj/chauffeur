import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct SkillTests {
    func frontMatter() -> [String: String] {
        let parts = Skill.skillMarkdown.components(separatedBy: "---\n")
        var fields: [String: String] = [:]
        for line in parts[1].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    @Test func followsTheAgentSkillsFormat() {
        #expect(Skill.skillMarkdown.hasPrefix("---\nname: chauffeur\n"))
        let fields = frontMatter()
        #expect(fields["name"] == "chauffeur")  // must match the folder name
        let description = fields["description"] ?? ""
        #expect(!description.isEmpty && description.count <= 1024)
        #expect((fields["compatibility"] ?? "").count <= 500)
        #expect(Skill.skillMarkdown.split(separator: "\n").count < 500)
    }

    @Test func teachesTheLoopTheBuildAndTheTrustRule() {
        for text in [Skill.skillMarkdown, Skill.agentsSection] {
            #expect(text.contains("chauffeur snapshot") && text.contains("xcodebuild") && text.contains("chauffeur install"))
            #expect(text.contains("untrusted data"))
        }
        for command in ["snapshot", "find", "wait", "tap", "type", "scroll", "swipe", "button", "open", "logs", "screenshot",
                        "permission", "location", "push", "appearance", "do", "doctor", "install", "launch"] {
            #expect(Skill.skillMarkdown.contains("`\(command)") || Skill.skillMarkdown.contains("chauffeur \(command)"), "\(command)")
            #expect(Usage.text.contains("\n  \(command) "), "\(command) is missing from Usage")
        }
    }

    @Test func warnsThatTabItemsGetNewRefs() {
        #expect(Skill.skillMarkdown.contains("Tab-bar items get new refs after a tab switch; re-find them (e.g. `find tab:Home`)"))
    }

    @Test func installIsIdempotentAndKeepsTheUsersAgentsMD() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cht-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agentsMD = root.appendingPathComponent("AGENTS.md")
        try "# My project\n\nUse tabs.\n".write(to: agentsMD, atomically: true, encoding: .utf8)

        let lines = try Skill.install(agents: Skill.agents, in: root)
        #expect(lines == ["wrote .claude/skills/chauffeur/SKILL.md (Claude Code)", "updated AGENTS.md (Codex, Cursor)"])
        let skill = try String(contentsOf: root.appendingPathComponent(".claude/skills/chauffeur/SKILL.md"), encoding: .utf8)
        #expect(skill == Skill.skillMarkdown + "\n")

        let edited = try String(contentsOf: agentsMD, encoding: .utf8).replacingOccurrences(of: "## iOS Simulator", with: "## stale")
        try edited.write(to: agentsMD, atomically: true, encoding: .utf8)
        _ = try Skill.install(agents: ["codex"], in: root)
        let text = try String(contentsOf: agentsMD, encoding: .utf8)
        #expect(text.hasPrefix("# My project\n\nUse tabs.\n\n<!-- chauffeur:begin"))
        #expect(text.components(separatedBy: "<!-- chauffeur:begin").count == 2)  // exactly one section
        #expect(!text.contains("## stale") && text.hasSuffix("<!-- chauffeur:end -->\n"))
    }

    @Test @MainActor func theCLIChecksTheAgentNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cht-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let e = CLI.Environment(env: [:], cwd: root, devices: { [] }, send: { _, _ in Output("unexpected") })
        #expect(CLI.handle(["skill", "install", "--agents", "claude,vim"], e).exit == 64)
        let out = CLI.handle(["skill", "install", "--agents", "cursor"], e)
        #expect(out.exit == 0 && out.text.hasPrefix("wrote AGENTS.md (Cursor)"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
    }

    @Test func skillSaysWhenToLookAtPixels() { #expect(Skill.skillMarkdown.contains("Take a screenshot to check how something looks")) }
}
