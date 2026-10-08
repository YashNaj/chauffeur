import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct BatchTests {
    @Test func semicolonsSplitCommandsButNotQuotedText() throws {
        #expect(try Batch.parse(#"tap e4; type e5 "hello; world" --submit; scroll down"#)
                == [["tap", "e4"], ["type", "e5", "hello; world", "--submit"], ["scroll", "down"]])
        #expect(try Batch.parse("tap e1\ntap e2") == [["tap", "e1"], ["tap", "e2"]])
        #expect(try Batch.parse(";; tap e1 ;") == [["tap", "e1"]])
    }

    @Test func quotesAndEscapesWorkLikeAShell() throws {
        #expect(try Batch.parse(#"type e5 'say "hi"\n'"#) == [["type", "e5", #"say "hi"\n"#]])
        #expect(try Batch.parse(#"type e1 "a \"b\" c\\d \n""#) == [["type", "e1", #"a "b" c\d \n"#]])
        #expect(try Batch.parse(#"find \;"#) == [["find", ";"]])
        #expect(try Batch.parse(#"type e1 """#) == [["type", "e1", ""]])
        #expect(try Batch.parse(#"type e1 -- "--submit""#) == [["type", "e1", "--", "--submit"]])
    }

    @Test func brokenScriptsAreUsageErrors() {
        #expect(throws: ChauffeurError.self) { try Batch.parse(#"type e1 "unterminated"#) }
        #expect(throws: ChauffeurError.self) { try Batch.parse(#"tap e1 \"#) }
    }

    @Test func renderingQuotesWhatNeedsIt() {
        #expect(Batch.render(["type", "e5", "hello; world"]) == #"type e5 "hello; world""#)
        #expect(Batch.render(["type", "e5", "two\nlines"]) == #"type e5 "two\nlines""#)
        #expect(Batch.render(["tap", "e4"]) == "tap e4")
    }

    @Test @MainActor func aBatchChecksNamesFirstAndStopsAtTheFirstFailure() throws {
        let s = Session(udid: "ZZ000000-TEST")
        #expect(throws: ChauffeurError.self) { try s.batchCommand(["tap e1; tpa e2"]) }  // nothing runs
        #expect(throws: ChauffeurError.self) { try s.batchCommand(["do 'tap e1'"]) }  // no nesting
        let out = try s.batchCommand(["tap; logs"])  // `tap` without a target is a usage error (64)
        #expect(out.exit == 64)
        #expect(out.text.hasPrefix("[1/2] usage: chauffeur tap"))
        #expect(out.text.hasSuffix("stopped at [1/2] (exit 64); not run: logs"))
        #expect(out.data?["results"]?.array?.count == 1)
    }
}
