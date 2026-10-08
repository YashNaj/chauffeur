import Testing

@testable import ChauffeurCore

@Suite struct QueryTests {
    let screen = Size(w: 402, h: 874)

    @Test func findByTextAndRole() throws {
        var refs = RefTable()
        let snap = Perception.build(
            root: try Fixtures.ax("fixture-home"), size: screen, previous: nil, refs: &refs, rev: 1)
        #expect(snap.find("alert").map(\.ref) == ["e1"])
        #expect(snap.find("button:request").map(\.ref) == ["e2", "e3"])
        #expect(snap.find("heading:alert").isEmpty)
        #expect(snap.find("lastaction").first?.name == "Last action: none")  // identifier match
    }

    @Test func resolvesLiveStaleAndUnknownRefs() throws {
        var refs = RefTable()
        let home = Perception.build(
            root: try Fixtures.ax("fixture-home"), size: screen, previous: nil, refs: &refs, rev: 1)
        let form = Perception.build(
            root: try Fixtures.ax("fixture-form"), size: screen, previous: nil, refs: &refs, rev: 2)
        #expect(try home.resolve(ref: "e1", refs: refs).name == "Show alert")
        #expect(throws: RefError.stale("e1", name: "Show alert")) { try form.resolve(ref: "e1", refs: refs) }
        #expect(throws: RefError.unknown("e99")) { try form.resolve(ref: "e99", refs: refs) }
        #expect(
            RefError.stale("e1", name: "Show alert").description
                == "stale ref e1 (\"Show alert\") — not on screen; run snapshot")
    }

    @Test func diffShowsChangedLinesOnly() throws {
        var refs = RefTable()
        let root = try Fixtures.ax("fixture-home")
        var after = root
        after.children[1].children[1].label = "Last action: alert ok"
        let a = Perception.build(root: root, size: screen, previous: nil, refs: &refs, rev: 1)
        let b = Perception.build(root: after, size: screen, previous: nil, refs: &refs, rev: 2)
        #expect(Diff.lines(from: a, to: b) == ["- text \"Last action: none\"", "+ text \"Last action: alert ok\""])
        #expect(Diff.lines(from: a, to: a).isEmpty)
    }

    @Test func diffIsCapped() throws {
        var refs = RefTable()
        let home = Perception.build(
            root: try Fixtures.ax("fixture-home"), size: screen, previous: nil, refs: &refs, rev: 1)
        let list = Perception.build(
            root: try Fixtures.ax("fixture-longlist"), size: screen, previous: nil, refs: &refs, rev: 2)
        let lines = Diff.lines(from: home, to: list, limit: 5)
        #expect(lines.count == 6)
        #expect(lines.last?.hasPrefix("… ") == true)
        #expect(lines.last?.hasSuffix("more changes — run snapshot") == true)
    }

    @Test func cappedDiffShowsWhatAppearedFirst() throws {
        // A full-screen change (home → alert) must still show the alert when the diff is cut.
        var refs = RefTable()
        let home = Perception.build(
            root: try Fixtures.ax("fixture-home"), size: screen, previous: nil, refs: &refs, rev: 1)
        let alertRoot = AXElement(
            role: "AXApplication", label: "Fixture", frame: Rect(x: 0, y: 0, w: 402, h: 874),
            children: [
                AXElement(role: "AXStaticText", label: "Fixture alert", frame: Rect(x: 71, y: 410, w: 260, h: 20)),
                AXElement(role: "AXButton", label: "Cancel", frame: Rect(x: 57, y: 450, w: 140, h: 48)),
                AXElement(role: "AXButton", label: "OK", frame: Rect(x: 205, y: 450, w: 140, h: 48)),
            ])
        let alert = Perception.build(root: alertRoot, size: screen, previous: home.kind, refs: &refs, rev: 2)
        let lines = Diff.lines(from: home, to: alert, limit: 5)
        #expect(
            Array(lines.prefix(3)) == ["+ text \"Fixture alert\"", "+ button \"Cancel\" [e6]", "+ button \"OK\" [e7]"])
        #expect(lines.count == 6 && lines.last == "… 7 more changes — run snapshot")
    }
}
