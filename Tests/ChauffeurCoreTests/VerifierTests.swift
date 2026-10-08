import Testing

@testable import ChauffeurCore

@Suite struct VerifierTests {
    func classify(_ changed: Bool, _ e: Evidence, expected: String? = nil, system: Bool = false, retried: Bool = false)
        -> Outcome
    {
        Verifier.classify(
            treeChanged: changed, evidence: e, expectedApp: expected, systemFrontmost: system, retried: retried)
    }

    @Test func decisionTable() {
        #expect(classify(true, .none) == .changed)
        #expect(classify(true, .unavailable) == .changed)
        #expect(classify(false, .app("dev.chauffeur.fixture")) == .noEffect)
        #expect(classify(false, .app("com.other"), expected: "dev.chauffeur.fixture") == .intercepted("com.other"))
        #expect(classify(false, .system) == .intercepted("system UI (SpringBoard)"))
        #expect(classify(false, .system, system: true) == .noEffect)
        #expect(classify(false, .none) == .retry)
        #expect(classify(false, .none, retried: true) == .notDelivered)
        #expect(classify(false, .unavailable) == .unverified)
    }

    let submit = Node(
        role: "button", name: "Submit", value: nil, identifier: nil, enabled: false,
        frame: Rect(x: 16, y: 324, w: 370, h: 52), depth: 0,
        identity: Identity(role: "button", key: "Submit", ancestor: nil, ordinal: 0), ref: "e4")

    @Test func reportsNeverSayOkForANoOp() {
        let r = ActionReport(
            action: "tap e4 \"Submit\"", outcome: .noEffect, evidence: .app("dev.chauffeur.fixture"),
            settledMs: 1500, settled: true, revBefore: 3, revAfter: 3, diff: [], transport: "digitizer",
            retriedFrom: nil, hints: Verifier.hints(outcome: .noEffect, target: submit), capMs: 1500)
        #expect(
            r.render() == """
                tap e4 "Submit" → NO EFFECT · the accessibility tree did not change in 1.5s (touch reached dev.chauffeur.fixture)
                hint: e4 is disabled; fill in or select whatever it depends on first, then retry
                """)
        #expect(r.exitCode == 3)
    }

    @Test func noEffectSaysWhatWasCompared() {
        var r = ActionReport(
            action: "tap e71 \"Dark\"", outcome: .noEffect, evidence: .app("com.apple.Preferences"),
            settledMs: 0, settled: true, revBefore: 3, revAfter: 3, diff: [], transport: "digitizer",
            retriedFrom: nil, hints: [], capMs: 1500)
        r.evidenceShot = "/tmp/shot.jpg"
        let text = r.render()
        #expect(text.hasPrefix("tap e71 \"Dark\" → NO EFFECT · the accessibility tree did not change in 1.5s"))
        #expect(
            text.contains(
                "\nscreen: /tmp/shot.jpg (look before retrying: some changes, like checkmarks, never reach the tree)"))
        #expect(r.json["screenshot"] == "/tmp/shot.jpg")
    }

    @Test func theEvidenceRegionIsTheTargetRowPlusMarginClampedToTheScreen() {
        let screen = Size(w: 402, h: 874)
        #expect(
            Verifier.evidenceRegion(target: Rect(x: 16, y: 272, w: 370, h: 52), screen: screen)
                == Rect(x: 0, y: 152, w: 402, h: 292))
        #expect(
            Verifier.evidenceRegion(target: Rect(x: 0, y: 0, w: 50, h: 20), screen: screen)
                == Rect(x: 0, y: 0, w: 402, h: 140))
    }

    @Test func changedReportCarriesDiff() {
        let r = ActionReport(
            action: "tap e1 \"Show alert\"", outcome: .changed, evidence: .app("x"), settledMs: 340,
            settled: true, revBefore: 7, revAfter: 8, diff: ["+ text \"Fixture alert\""],
            transport: "digitizer", retriedFrom: nil, hints: [], capMs: 1500)
        #expect(r.render() == "tap e1 \"Show alert\" → changed · settled 340ms · rev 7→8\n+ text \"Fixture alert\"")
        #expect(r.exitCode == 0)
    }

    @Test func retriedAndUndelivered() {
        let retried = ActionReport(
            action: "tap (201,344)", outcome: .changed, evidence: .app("x"), settledMs: 200,
            settled: false, revBefore: 1, revAfter: 2, diff: [], transport: "mouse",
            retriedFrom: "digitizer", hints: [], capMs: 1500)
        #expect(
            retried.render()
                == "tap (201,344) → changed · still changing at 1.5s · rev 1→2 · via mouse after digitizer showed no touch"
        )
        let lost = ActionReport(
            action: "tap (201,344)", outcome: .notDelivered, evidence: .none, settledMs: 1500,
            settled: true, revBefore: 1, revAfter: 1, diff: [], transport: "mouse",
            retriedFrom: "digitizer", hints: Verifier.hints(outcome: .notDelivered, target: nil), capMs: 1500)
        #expect(
            lost.render() == """
                tap (201,344) → NOT DELIVERED · retried via mouse · still no touch
                hint: input transport unhealthy — run `chauffeur doctor --live`
                """)
    }

    @Test func unverifiedIsNeverOk() {
        let r = ActionReport(
            action: "tap e1", outcome: .unverified, evidence: .unavailable, settledMs: 1500, settled: true,
            revBefore: 1, revAfter: 1, diff: [], transport: "digitizer", retriedFrom: nil,
            hints: Verifier.hints(outcome: .unverified, target: nil), capMs: 1500)
        #expect(r.render().hasPrefix("tap e1 → UNVERIFIED: no visible change"))
        #expect(r.exitCode == 3)
    }

    @Test func unverifiedSaysWhyAndReportsAreData() {
        var r = ActionReport(
            action: "open \"fixture://x\"", outcome: .unverified, evidence: .unavailable, settledMs: 3000,
            settled: true, revBefore: 4, revAfter: 4, diff: [], transport: "none", retriedFrom: nil,
            hints: ["run snapshot"], capMs: 3000)
        r.note = "the URL was delivered; nothing visible changed in 3s"
        #expect(
            r.render()
                == "open \"fixture://x\" → UNVERIFIED: no visible change (the URL was delivered; nothing visible changed in 3s)\nhint: run snapshot"
        )
        #expect(r.exitCode == 3)
        #expect(
            r.json["outcome"] == "unverified" && r.json["rev"] == [4, 4]
                && r.json["note"]?.string?.hasPrefix("the URL") == true)
        let blocked = ActionReport(
            action: "tap e1", outcome: .intercepted("com.apple.springboard"), evidence: .app("com.apple.springboard"),
            settledMs: 1500, settled: true, revBefore: 1, revAfter: 1, diff: [], transport: "digitizer",
            retriedFrom: nil, hints: [], capMs: 1500)
        #expect(
            blocked.json["interceptedBy"] == "com.apple.springboard"
                && blocked.json["evidence"] == "app:com.apple.springboard")
    }

    func field(_ role: String, _ value: String?) -> Node {
        Node(
            role: role, name: "f", value: value, identifier: nil, enabled: true, frame: Rect(x: 0, y: 0, w: 10, h: 10),
            depth: 0, identity: Identity(role: role, key: "f", ancestor: nil, ordinal: 0), ref: "e1")
    }

    @Test func typeChecks() {
        #expect(
            TypeCheck.verify(
                typed: "Ab@1", before: field("textfield", ""), after: field("textfield", "Ab@1"), submitted: false)
                == .ok)
        #expect(
            TypeCheck.verify(
                typed: "café", before: field("textfield", ""), after: field("textfield", "caf"), submitted: false)
                == .mismatch("caf"))
        #expect(
            TypeCheck.verify(
                typed: "hunter2", before: field("securefield", ""), after: field("securefield", "•••••••"),
                submitted: false) == .ok)
        #expect(
            TypeCheck.verify(
                typed: "hunter2", before: field("securefield", "••"), after: field("securefield", "•••••"),
                submitted: false) == .mismatch("•••••"))
        #expect(TypeCheck.verify(typed: "x", before: field("textfield", ""), after: nil, submitted: true) == .ok)
        #expect(
            TypeCheck.verify(typed: "x", before: field("textfield", ""), after: nil, submitted: false) == .fieldGone)
    }

    @Test func typeReports() {
        let ok = TypeReport(action: "type e1 \"Ab@1\"", method: "keys", verdict: .ok, value: "Ab@1", settledMs: 210)
        #expect(ok.render() == "type e1 \"Ab@1\" → typed via keys · value=\"Ab@1\" · settled 210ms")
        #expect(ok.exitCode == 0)
        let bad = TypeReport(
            action: "type e1 \"café\"", method: "paste", verdict: .mismatch("caf"), value: "caf", settledMs: 300)
        #expect(
            bad.render() == """
                type e1 "café" → TEXT MISMATCH via paste · field shows "caf"
                hint: the field may limit or reformat input; run snapshot to see it
                """)
        #expect(bad.exitCode == 3)
        let gone = TypeReport(action: "type e1 \"x\"", method: "keys", verdict: .fieldGone, value: nil, settledMs: 300)
        #expect(gone.render() == "type e1 \"x\" → FIELD GONE after typing · run snapshot")
    }
}
