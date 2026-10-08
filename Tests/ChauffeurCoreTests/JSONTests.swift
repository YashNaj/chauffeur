import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct JSONTests {
    @Test func roundTripsAndKeepsWholeNumbersWhole() throws {
        let text = #"{"id":1,"params":{"name":"tap","ratio":0.5,"tags":["a",true,null]}}"#
        let value = try JSON.parse(Data(text.utf8))
        #expect(value["id"]?.int == 1)
        #expect(value["params"]?["ratio"]?.number == 0.5)
        #expect(value.line() == text)
    }

    @Test func literalsBuildObjects() {
        let v: JSON = ["exit": 3, "ok": false, "path": "/tmp/a b", "none": nil, "list": [1, "x"]]
        #expect(v.line() == #"{"exit":3,"list":[1,"x"],"none":null,"ok":false,"path":"/tmp/a b"}"#)
    }

    @Test func linesNeverContainRawNewlines() {
        let v: JSON = ["text": "line 1\nline 2 \u{2028} \"q\""]
        #expect(!v.line().contains("\n"))
        #expect(v.line().contains(#"line 1\nline 2"#))
    }

    @Test func mergingAddsKeys() {
        let base: JSON = ["a": 1]
        #expect(base.merging(["b": 2]) == ["a": 1, "b": 2])
        #expect(JSON.null.merging(["b": 2]) == ["b": 2])
    }

    @Test func outputJSONLine() {
        #expect(Output("hi", exit: 4).jsonLine() == #"{"data":null,"exit":4,"text":"hi"}"#)
        let old = try? JSONDecoder().decode(Output.self, from: Data(#"{"text":"x","exit":0}"#.utf8))
        #expect(old == Output("x"))  // a daemon from before `data` still decodes
    }
}
