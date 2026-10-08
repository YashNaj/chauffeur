import Testing

@testable import ChauffeurCore

/// `--json` carries the same data as the text (spec §5.1).
@Suite struct JSONDataTests {
    let screen = Size(w: 402, h: 874)

    @Test func snapshotsAsData() throws {
        var refs = RefTable()
        let snap = Perception.build(
            root: try Fixtures.ax("fixture-form"), size: screen, previous: nil, refs: &refs, rev: 3)
        let json = snap.json(all: false)
        #expect(json["kind"] == "app" && json["app"] == "Fixture" && json["screen"] == "Form" && json["rev"] == 3)
        #expect(json["size"] == [402, 874] && json["orientation"] == "portrait")
        let nodes = try #require(json["nodes"]?.array)
        #expect(nodes.count == snap.nodes.count)
        let submit = try #require(nodes.first { $0["name"] == "Submit" })
        #expect(
            submit["role"] == "button" && submit["ref"] == "e4" && submit["enabled"] == false && submit["frame"] == nil)
        #expect(snap.json(all: true)["nodes"]?.array?.first?["frame"]?.array?.count == 4)
    }

    @Test func typeReportsAsData() {
        let ok = TypeReport(action: "type e1 \"Ab\"", method: "keys", verdict: .ok, value: "Ab", settledMs: 200)
        #expect(
            ok.json == ["action": "type e1 \"Ab\"", "method": "keys", "value": "Ab", "settledMs": 200, "verdict": "ok"])
        let bad = TypeReport(action: "a", method: "paste", verdict: .mismatch("caf"), value: "caf", settledMs: 1)
        #expect(bad.json["verdict"] == "mismatch" && bad.json["shown"] == "caf")
    }

    @Test func doctorChecksAsData() {
        let out = Doctor.output([Check(status: .ok, text: "Xcode 27.0"), Check(status: .fail, text: "no tree")])
        #expect(out.exit == 1)
        #expect(
            out.data == ["checks": [["status": "ok", "text": "Xcode 27.0"], ["status": "fail", "text": "no tree"]]])
    }

    @Test func staleRefsNameTheLabelNotTheIdentifier() throws {
        // M1 review minor: an element with an accessibility identifier used to be named by that identifier.
        var refs = RefTable()
        let signIn = AXElement(
            role: "AXButton", label: "Sign in", identifier: "signInButton", frame: Rect(x: 20, y: 400, w: 360, h: 50))
        let before = AXElement(
            role: "AXApplication", label: "App", frame: Rect(x: 0, y: 0, w: 402, h: 874), children: [signIn])
        let after = AXElement(role: "AXApplication", label: "App", frame: Rect(x: 0, y: 0, w: 402, h: 874))
        _ = Perception.build(root: before, size: screen, previous: nil, refs: &refs, rev: 1)
        let gone = Perception.build(root: after, size: screen, previous: nil, refs: &refs, rev: 2)
        #expect(throws: RefError.stale("e1", name: "Sign in")) { try gone.resolve(ref: "e1", refs: refs) }
    }
}
