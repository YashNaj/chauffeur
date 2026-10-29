import Testing

@testable import ChauffeurCore

/// `credit`: the one way a NO EFFECT becomes a change (Stage 2, Task 14).
@MainActor
struct CreditTests {
    private func snapshots() throws -> (before: Snapshot, after: Snapshot) {
        var refs = RefTable()
        let before = Perception.build(
            root: try Act.home(), size: Act.screen, previous: nil, refs: &refs, rev: 7)
        let after = Perception.build(
            root: try Act.form(), size: Act.screen, previous: nil, refs: &refs, rev: 8)
        return (before, after)
    }

    private func noEffect(revAfter: Int = 7, diff: [String] = []) -> ActionReport {
        var r = ActionReport(
            action: "tap e4 \"Login\"", outcome: .noEffect, evidence: .app("dev.chauffeur.fixture"), settledMs: 150,
            settled: true, revBefore: 7, revAfter: revAfter, diff: diff, transport: "digitizer", retriedFrom: nil,
            hints: Verifier.hints(outcome: .noEffect, target: nil), capMs: 1500)
        r.evidenceShot = "$TMPDIR/shot.jpg"
        return r
    }

    @Test func creditingAChangeSetsTheVerdictAndTheDiff() throws {
        let (before, after) = try snapshots()
        var report = noEffect()
        report.credit(change: after, from: before, settledMs: 420, settled: true)

        let expected = Diff.lines(from: before, to: after)
        #expect(!expected.isEmpty)
        #expect(report.outcome == .changed)
        #expect(report.diff == expected)
        #expect(report.revAfter == after.rev)
        #expect(report.settledMs == 420)
        #expect(report.settled)
        #expect(report.hints == [])
        #expect(report.evidenceShot == nil)

        var direct = ActionReport(
            action: "tap e4 \"Login\"", outcome: .changed, evidence: .app("dev.chauffeur.fixture"), settledMs: 420,
            settled: true, revBefore: 7, revAfter: after.rev, diff: expected, transport: "digitizer",
            retriedFrom: nil, hints: [], capMs: 1500)
        direct.requestElapsedMs = report.requestElapsedMs
        #expect(report.render() == direct.render())
        #expect(report.json == direct.json)
    }

    @Test func creditingAChangeKeepsTheHintsItIsGiven() throws {
        let (before, after) = try snapshots()
        var report = noEffect()
        report.credit(
            change: after, from: before, settledMs: 150, settled: false, hints: ["the switch changed only after 1.5s"])
        #expect(report.hints == ["the switch changed only after 1.5s"])
        #expect(!report.settled)
        #expect(report.evidenceShot == nil)
    }

    @Test func creditingACopyLeavesTheRevisionsAndTheSettle() {
        var report = noEffect()
        report.credit(copied: 24)
        #expect(report.outcome == .changed)
        #expect(report.copiedCharacters == 24)
        #expect(report.hints == [])
        #expect(report.evidenceShot == nil)
        #expect(report.revAfter == 7)
        #expect(report.settledMs == 150)
        #expect(
            report.render().split(separator: "\n").first?.hasSuffix("→ changed · copied to clipboard (24 characters)")
                == true)
    }
}
