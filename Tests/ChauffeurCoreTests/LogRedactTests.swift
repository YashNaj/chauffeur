import Testing

@testable import ChauffeurCore

/// M4b spec §6 ("logs follow the same rule"): Apple's networking lines never show a query, token or email.
@Suite struct LogRedactTests {
    func framework(_ message: String, sender: String = "Network") -> LogLine {
        LogLine(time: "t", level: "default", message: message, sender: sender)
    }

    @Test func connectionURLsAreShaped() {
        let line = framework(
            "[C1 B47F Hostname#a88a3e8b:8765 tcp, url: http://localhost:8765/reset/sam@example.com/7f3a9c1e5b2d4f60a8b1?t=1, definite]"
        )
        #expect(
            LogRedact.line(line).message
                == "[C1 B47F Hostname#a88a3e8b:8765 tcp, url: http://localhost:8765/reset/{email}/{token}, definite]")
    }

    @Test func failingURLsInErrorLinesAreShaped() {
        let line = framework(
            "Task <E8F6>.<3> finished with error [-1004] UserInfo={NSErrorFailingURLStringKey=https://api.example.com/u/8812?token=abc, NSErrorFailingURLKey=https://api.example.com/u/8812?token=abc, _kCFStreamErrorDomainKey=1}",
            sender: "CFNetwork")
        #expect(
            LogRedact.line(line).message
                == "Task <E8F6>.<3> finished with error [-1004] UserInfo={NSErrorFailingURLStringKey=https://api.example.com/u/{id}, NSErrorFailingURLKey=https://api.example.com/u/{id}, _kCFStreamErrorDomainKey=1}"
        )
    }

    @Test func credentialsInAURLAreDropped() {
        #expect(LogRedact.urls(in: "url: https://bob:hunter2@api.example.com/x,") == "url: https://api.example.com/x,")
    }

    @Test func aURLWithoutAPathKeepsItsHost() {
        #expect(LogRedact.urls(in: "url: https://api.example.com?q=1, x") == "url: https://api.example.com/, x")
        #expect(LogRedact.urls(in: "url: https://api.example.com, x") == "url: https://api.example.com, x")
    }

    @Test func theAppsOwnLinesAreLeftAlone() {
        let own = LogLine(time: "t", level: "info", message: "fetching https://api.example.com/u/8812?token=abc")
        #expect(LogRedact.line(own) == own)
    }

    @Test func logTapStoresShapedLines() {
        let tap = LogTap(udid: "TEST")
        tap.append(framework("[C2 url: https://api.example.com/a/123?q=secret, definite]"))
        #expect(tap.all.map(\.message) == ["[C2 url: https://api.example.com/a/{id}, definite]"])
    }
}
