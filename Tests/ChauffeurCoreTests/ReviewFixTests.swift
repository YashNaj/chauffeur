import Darwin
import Foundation
import Testing

@testable import ChauffeurCore

/// Regression tests for the final-review findings (C1, I1–I6).
@Suite struct ReviewFixTests {
    // C1: only one daemon per simulator.
    @Test func daemonLockIsExclusive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cht-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(DaemonLock.acquire(url))
        #expect(DaemonLock.acquire(url) == nil)
        first.release()
        #expect(DaemonLock.acquire(url) != nil)
    }

    // C1: a daemon only removes a socket file it created itself.
    @Test func finishLeavesASuccessorsSocketAlone() throws {
        let path = NSTemporaryDirectory() + "cht-\(UInt32.random(in: 0...UInt32.max)).sock"
        let old = try UnixSocket.listen(path: path)
        let oldInode = try #require(UnixSocket.inode(path))
        close(old)
        let new = try UnixSocket.listen(path: path)  // successor rebinds the same path
        defer {
            close(new)
            unlink(path)
        }
        UnixSocket.unlink(path, ifInode: oldInode)
        #expect(FileManager.default.fileExists(atPath: path))
        UnixSocket.unlink(path, ifInode: try #require(UnixSocket.inode(path)))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // C1: a slow or dropped reply must not spawn a second daemon; only "nobody is listening" does.
    @Test func clientStartsADaemonOnlyWhenNobodyListens() {
        #expect(DaemonClient.shouldStart(after: UnixSocket.Failure(description: "connect", code: ENOENT)))
        #expect(DaemonClient.shouldStart(after: UnixSocket.Failure(description: "connect", code: ECONNREFUSED)))
        #expect(!DaemonClient.shouldStart(after: UnixSocket.Failure(description: "read", code: EAGAIN)))
        #expect(!DaemonClient.shouldStart(after: ChauffeurError.daemon("connection dropped")))
    }

    // C1 trigger B: waits are bounded below the client's socket timeout.
    @Test func waitTimeoutIsCapped() {
        #expect(Session.waitTimeout(900) == Session.maxWaitSeconds)
        #expect(Session.waitTimeout(5) == 5)
        #expect(Session.waitTimeout(nil) == 10)
        #expect(Session.maxWaitSeconds < DaemonClient.replyTimeout)
    }

    // I1: a change on a screen that was already changing is not credited to the action.
    @Test func changeOnAnUnsettledScreenIsUnattributed() {
        #expect(
            Verifier.classify(
                treeChanged: true, evidence: .app("x"), expectedApp: nil, systemFrontmost: false,
                retried: false, baselineSettled: false) == .unattributed)
        #expect(
            Verifier.classify(
                treeChanged: true, evidence: .app("x"), expectedApp: nil, systemFrontmost: false,
                retried: false, baselineSettled: true) == .changed)
        let r = ActionReport(
            action: "tap e1", outcome: .unattributed, evidence: .app("x"), settledMs: 1500, settled: false,
            revBefore: 1, revAfter: 2, diff: [], transport: "digitizer", retriedFrom: nil,
            hints: Verifier.hints(outcome: .unattributed, target: nil), capMs: 1500)
        #expect(r.render().hasPrefix("tap e1 → UNVERIFIED: the screen was already changing"))
        #expect(r.exitCode == 3)
    }

    func field(_ value: String) -> Node {
        Node(
            role: "textfield", name: "f", value: value, identifier: nil, enabled: true,
            frame: Rect(x: 0, y: 0, w: 10, h: 10),
            depth: 0, identity: Identity(role: "textfield", key: "f", ancestor: nil, ordinal: 0), ref: "e1")
    }

    // I2: typed text must actually have been added.
    @Test func typingIntoAPrefilledFieldNeedsNewText() {
        #expect(
            TypeCheck.verify(typed: "a", before: field("banana"), after: field("banana"), submitted: false)
                == .mismatch("banana"))
        #expect(TypeCheck.verify(typed: "a", before: field("banana"), after: field("bananaa"), submitted: false) == .ok)
        #expect(TypeCheck.verify(typed: "x", before: field("x"), after: field("x"), submitted: false) == .mismatch("x"))
    }

    // I3: control and separator characters cannot forge snapshot lines.
    @Test func controlAndSeparatorCharactersAreEscaped() {
        #expect(Perception.quote("OK\rbutton \"Go\" [e9]") == #""OK\rbutton \"Go\" [e9]""#)
        #expect(Perception.quote("a\tb") == #""a\tb""#)
        #expect(Perception.quote("x\u{2028}system alert") == #""x\u{2028}system alert""#)
        #expect(Perception.quote("esc\u{1B}[31m") == #""esc\u{1B}[31m""#)
        #expect(Perception.quote("z\u{200B}w") == #""z\u{200B}w""#)
    }

    @Test func combiningMarksCannotDefeatTheCut() {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 10_000)
        #expect(Perception.quote(zalgo).unicodeScalars.count < 200)
    }

    // I4: the saved prior level survives a failed restore.
    @Test func priorLevelIsClearedOnlyAfterAVerifiedRestore() {
        #expect(PriorLevel.restored(status: 0, levelAfter: "info", prior: "info"))
        #expect(!PriorLevel.restored(status: 0, levelAfter: "debug", prior: "info"))
        #expect(!PriorLevel.restored(status: -1, levelAfter: nil, prior: "info"))
    }

    // I5: scroll regions are clipped to the screen, so drags never start on an edge.
    @Test func scrollRegionsAreClippedToTheScreen() throws {
        let screen = Size(w: 402, h: 874)
        let region = ScrollPlan.region(Rect(x: 0, y: -300, w: 402, h: 400), screen: screen)
        #expect(region == Rect(x: 0, y: 0, w: 402, h: 100))
        let up = try #require(ScrollPlan.drag("up", in: region))
        #expect(Geometry.refusal(for: up.from, screen: screen, allowEdge: false) == nil)
        #expect(Geometry.refusal(for: up.to, screen: screen, allowEdge: false) == nil)
    }

    // I6: dev builds carry a build stamp, so a rebuilt CLI replaces an old daemon.
    @Test func devBuildsAreDistinguishable() {
        #expect(Chauffeur.build(stamp: 1_700_000_000) == "0.1.1+1700000000")
        #expect(Chauffeur.build(stamp: 1_700_000_000) != Chauffeur.build(stamp: 1_700_000_001))
    }
}
