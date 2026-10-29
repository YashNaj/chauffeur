/// What a network pass writes on either report. `outcome` and `hints` are `ActionReport`'s alone: `TypeReport` has a
/// `verdict` and no hints, and gains nothing, so its JSON stays byte-identical.
protocol EvidenceCarrier {
    var requests: [RequestItem] { get set }
    var requestElapsedMs: Int { get set }
}

extension ActionReport: EvidenceCarrier {}
extension TypeReport: EvidenceCarrier {}

extension ActionReport {
    /// The one way a NO EFFECT becomes a change. `settledMs` and `settled` are passed, not computed: each site keeps
    /// its convention (the time since the touch, or the act's own settle, or the wait's observe). Sets outcome,
    /// revAfter, diff, settledMs, settled and hints; clears evidenceShot.
    mutating func credit(
        change after: Snapshot, from before: Snapshot, settledMs: Int, settled: Bool, hints: [String] = []
    ) {
        revAfter = after.rev
        diff = Diff.lines(from: before, to: after)
        self.settledMs = settledMs
        self.settled = settled
        crediting(hints: hints)
    }

    /// A copy is a change with nothing to show on screen: the revisions and the settle stay as the act left them.
    /// Sets outcome and copiedCharacters, empties hints; clears evidenceShot.
    mutating func credit(copied characters: Int) {
        copiedCharacters = characters
        crediting(hints: [])
    }

    private mutating func crediting(hints: [String]) {
        outcome = .changed
        self.hints = hints
        evidenceShot = nil
    }
}
