import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct LogStreamTests {
    @Test func recordsSplitAcrossChunksAreJoined() {
        var r = NDJSONReader()
        #expect(r.feed(Data("Filtering the log data using \"process == x\"\n{\"eventMes".utf8)).isEmpty)
        #expect(r.attached)
        let objects = r.feed(Data("sage\":\"hello\"}\n".utf8))
        #expect(objects.count == 1 && objects[0]["eventMessage"] as? String == "hello")
    }

    @Test func noHeaderAndNoRecordMeansNotAttached() {
        var r = NDJSONReader()
        #expect(r.feed(Data("xcrun: error: something\n".utf8)).isEmpty)
        #expect(!r.attached)
    }

    @Test func aRecordAloneProvesAttachment() {
        var r = NDJSONReader()
        #expect(r.feed(Data("{\"eventMessage\":\"x\"}\n".utf8)).count == 1)
        #expect(r.attached)
    }
}
