import Foundation

extension Session {
    /// What a batch may run: the daemon's commands, except `do` itself and `selftest`.
    static let batchable: Set<String> = logged.union(watched).union(["logs"])

    /// A batch starts no command after this long, so it stays under the client's 600 s reply timeout even when its
    /// last command is a 300 s wait.
    nonisolated static let batchBudgetMs = 240_000

    /// `do 'tap e4; type e5 "hi"; wait "Done"'`: runs in order and stops at the first failure (spec §5.1).
    func batchCommand(_ argv: [String]) throws -> Output {
        inBatch = true
        defer { inBatch = false }
        var a = try Args(argv, usage: "usage: chauffeur do '<command>; <command>; …'   (stops at the first failure)")
        guard let script = a.text() else { throw ChauffeurError.usage(a.usage) }
        let commands = try Batch.parse(script)
        guard !commands.isEmpty else { throw ChauffeurError.usage("the do script has no commands\n" + a.usage) }
        guard commands.count <= Batch.maxCommands else {
            throw ChauffeurError.usage(
                "a do script runs at most \(Batch.maxCommands) commands; this one has \(commands.count)")
        }
        // Check every name first, so a typo in the third command does not leave the first two done.
        for command in commands where !Self.batchable.contains(command[0]) {
            throw ChauffeurError.usage(
                "\(Perception.quote(command[0])) cannot run inside do; it runs: "
                    + Self.batchable.sorted().joined(separator: ", "))
        }
        let start = clock.nowMs()
        var parts: [String] = []
        var results: [JSON] = []
        var exit: Int32 = 0
        for (i, command) in commands.enumerated() {
            let tag = "[\(i + 1)/\(commands.count)]"
            let rest = commands[i...].map { Batch.render(Self.shown($0)) }.joined(separator: "; ")
            if clock.nowMs() - start >= Self.batchBudgetMs {
                parts.append("stopped before \(tag): the batch has run \(Self.batchBudgetMs / 1000)s; not run: \(rest)")
                exit = 1
                break
            }
            let out = runOne(command)
            parts.append(tag + " " + out.text)
            results.append([
                "argv": JSON(Self.shown(command)), "exit": JSON(Int(out.exit)), "text": .string(out.text),
                "data": out.data ?? .null,
            ])
            if out.exit != 0 {
                exit = out.exit
                let notRun = commands[(i + 1)...].map { Batch.render(Self.shown($0)) }.joined(separator: "; ")
                parts.append("stopped at \(tag) (exit \(out.exit))" + (notRun.isEmpty ? "" : "; not run: \(notRun)"))
                break
            }
        }
        return Output(
            parts.joined(separator: "\n"), exit: exit,
            data: ["results": .array(results), "total": JSON(commands.count)])
    }
}
