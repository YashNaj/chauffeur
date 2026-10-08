import Foundation
import Testing

@testable import ChauffeurCore

@Suite @MainActor struct MCPTests {
    final class Calls { var argv: [[String]] = [] }

    func server(_ output: Output = Output("ok")) -> (MCPServer, Calls) {
        let calls = Calls()
        let server = MCPServer(
            run: { argv in
                calls.argv.append(argv)
                return output
            }, readFile: { _ in Data([0xFF, 0xD8]) })
        return (server, calls)
    }

    static let meta: JSON = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    func request(_ method: String, id: JSON = 1, params: JSON? = nil) -> JSON {
        var o: [String: JSON] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
        if let params { o["params"] = params }
        return .object(o)
    }

    func call(_ tool: String, _ arguments: JSON, id: JSON = 1) -> JSON {
        request("tools/call", id: id, params: ["_meta": Self.meta, "name": .string(tool), "arguments": arguments])
    }

    @Test func legacyClientsNegotiateTheirRevision() {
        let (s, _) = server()
        let r = s.handle(
            request(
                "initialize",
                params: [
                    "protocolVersion": "2025-06-18", "capabilities": [:],
                    "clientInfo": ["name": "test", "version": "1"],
                ]))
        #expect(r?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(r?["result"]?["capabilities"]?["tools"] != nil && r?["result"]?["serverInfo"]?["name"] == "chauffeur")
        #expect(r?["result"]?["instructions"]?.string?.contains("untrusted") == true)
        #expect(s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let list = s.handle(request("tools/list", id: 2))
        #expect(list?["result"]?["tools"]?.array?.count == 7 && list?["result"]?["resultType"] == nil)
        #expect(s.handle(request("ping", id: 3))?["result"] == [:])
        let newer = s.handle(request("initialize", id: 4, params: ["protocolVersion": "2099-01-01"]))
        #expect(newer?["result"]?["protocolVersion"] == "2025-11-25")
    }

    @Test func modernRequestsAreServedStatelessly() {
        let (s, _) = server()
        let discover = s.handle(request("server/discover", params: ["_meta": Self.meta]))
        #expect(
            discover?["result"]?["supportedVersions"] == ["2026-07-28"]
                && discover?["result"]?["resultType"] == "complete")
        #expect(discover?["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "chauffeur")
        let list = s.handle(request("tools/list", id: "a", params: ["_meta": Self.meta]))
        #expect(
            list?["id"] == "a" && list?["result"]?["resultType"] == "complete"
                && list?["result"]?["tools"]?.array?.count == 7)
        #expect(s.legacyVersion == nil)
    }

    /// 2026-07-28 caching: discover and list results MUST carry ttlMs ≥ 0 and cacheScope; Claude Code rejects the
    /// whole tool list without them. Calls and legacy results carry neither.
    @Test func modernCacheableResultsCarryCachingHints() {
        let (s, _) = server()
        for method in ["server/discover", "tools/list"] {
            let r = s.handle(request(method, params: ["_meta": Self.meta]))?["result"]
            #expect((r?["ttlMs"]?.number ?? -1) > 0, "\(method)")
            #expect(r?["cacheScope"] == "public", "\(method)")
        }
        #expect(s.handle(call("doctor", [:]))?["result"]?["ttlMs"] == nil)
        let (legacy, _) = server()
        _ = legacy.handle(request("initialize", params: ["protocolVersion": "2025-06-18"]))
        #expect(legacy.handle(request("tools/list", id: 2))?["result"]?["ttlMs"] == nil)
    }

    @Test func eraAndProtocolErrorsFollowTheSpec() {
        let (s, _) = server()
        let old = s.handle(
            request(
                "tools/list",
                params: [
                    "_meta": [
                        "io.modelcontextprotocol/protocolVersion": "1900-01-01",
                        "io.modelcontextprotocol/clientCapabilities": [:],
                    ]
                ]))
        #expect(old?["error"]?["code"] == -32022)
        #expect(
            old?["error"]?["data"]?["supported"] == ["2026-07-28"]
                && old?["error"]?["data"]?["requested"] == "1900-01-01")
        let noCapabilities = s.handle(
            request("tools/list", params: ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]))
        #expect(noCapabilities?["error"]?["code"] == -32602)
        #expect(s.handle(request("tools/list"))?["error"]?["code"] == -32602)  // neither initialize nor _meta
        #expect(s.handle(request("resources/list", params: ["_meta": Self.meta]))?["error"]?["code"] == -32601)
        let garbage = s.respond(toLine: Data("{not json".utf8))
        #expect(garbage?["error"]?["code"] == -32700 && garbage?["id"] == .null)
        #expect(s.respond(toLine: Data("   ".utf8)) == nil)
        #expect(s.handle(["jsonrpc": "2.0", "id": 9, "result": [:]]) == nil)  // a response: nothing to answer
    }

    @Test func toolCallsRunTheCLIWithFreeTextAfterDoubleDash() {
        let (s, calls) = server(Output("type e2 \"--submit\" → TEXT MISMATCH via keys", exit: 3))
        let r = s.handle(call("act", ["action": "type", "target": "e2", "text": "--submit", "submit": true]))
        #expect(calls.argv == [["type", "--submit", "--", "e2", "--submit"]])
        #expect(r?["result"]?["isError"] == true)
        #expect(
            r?["result"]?["content"] == [["type": "text", "text": "type e2 \"--submit\" → TEXT MISMATCH via keys"]])
    }

    @Test func everyToolMapsToTheCLI() throws {
        func argv(_ tool: String, _ arguments: JSON) throws -> [String] {
            try MCPTools.argv(tool: tool, arguments: arguments) { _ in "/tmp/p.json" }
        }
        #expect(try argv("snapshot", [:]) == ["snapshot"])
        #expect(try argv("snapshot", ["all": true, "udid": "AAAA"]) == ["--udid", "AAAA", "snapshot", "--all"])
        #expect(try argv("snapshot", ["find": "button:Save"]) == ["find", "--", "button:Save"])
        #expect(
            try argv("snapshot", ["wait_for": "Done", "gone": true, "timeout": 2.5]) == [
                "wait", "--gone", "--timeout", "2.5", "--", "Done",
            ])
        #expect(
            try argv("act", ["action": "tap", "target": "201,344", "long": 1]) == [
                "tap", "--long", "1", "--", "201,344",
            ])
        #expect(
            try argv("act", ["action": "scroll", "direction": "down", "in": "e7", "until": "Row 40"])
                == ["scroll", "--in", "e7", "--until", "Row 40", "--", "down"])
        #expect(
            try argv("act", ["action": "swipe", "from": "201,650", "to": "201,250", "edge": true])
                == ["swipe", "--edge", "--", "201,650", "201,250"])
        #expect(try argv("act", ["action": "button", "button": "home"]) == ["button", "--", "home"])
        #expect(try argv("act", ["action": "batch", "commands": "tap e1; tap e2"]) == ["do", "--", "tap e1; tap e2"])
        #expect(try argv("screenshot", ["zoom": "e4"]) == ["screenshot", "--zoom", "e4"])
        #expect(
            try argv("logs", ["since_last": true, "level": "error"]) == ["logs", "--since-last", "--level", "error"])
        #expect(try argv("logs", ["last": 50]) == ["logs", "--last", "50"])
        #expect(
            try argv("app", ["action": "launch", "bundle": "dev.x", "args": ["--json", "-v"]]) == [
                "launch", "dev.x", "--args", "--json", "-v",
            ])
        #expect(try argv("app", ["action": "install", "path": "build/App.app"]) == ["install", "--", "build/App.app"])
        #expect(try argv("app", ["action": "open", "url": "myapp://x"]) == ["open", "--", "myapp://x"])
        #expect(try argv("app", ["action": "terminate", "bundle": "dev.x"]) == ["terminate", "--", "dev.x"])
        #expect(
            try argv("device", ["action": "permission", "mode": "grant", "service": "location", "bundle": "dev.x"])
                == ["permission", "--", "grant", "location", "dev.x"])
        #expect(
            try argv("device", ["action": "location", "location": "37.33,-122.01"]) == [
                "location", "--", "37.33,-122.01",
            ])
        #expect(
            try argv("device", ["action": "push", "bundle": "dev.x", "payload": ["aps": ["alert": "Hi"]]])
                == ["push", "--", "dev.x", "/tmp/p.json"])
        #expect(try argv("device", ["action": "appearance", "mode": "dark"]) == ["appearance", "--", "dark"])
        #expect(try argv("doctor", ["live": true]) == ["doctor", "--live"])
    }

    @Test func badArgumentsAreToolErrorsTheModelCanFix() {
        let (s, calls) = server()
        let missing = s.handle(call("act", ["action": "tap"]))
        #expect(missing?["result"]?["isError"] == true)
        #expect(missing?["result"]?["content"]?.array?.first?["text"] == "act tap needs target")
        let typo = s.handle(call("snapshot", ["fnd": "x"], id: 2))
        #expect(typo?["result"]?["isError"] == true)
        #expect(
            typo?["result"]?["content"]?.array?.first?["text"]?.string?.hasPrefix("snapshot has no argument \"fnd\"")
                == true)
        let wrongType = s.handle(call("act", ["action": "tap", "target": 4], id: 3))
        #expect(wrongType?["result"]?["content"]?.array?.first?["text"] == "target must be a string")
        #expect(calls.argv.isEmpty)
        #expect(s.handle(call("erase", [:], id: 4))?["error"]?["code"] == -32602)
    }

    @Test func pushPayloadsTravelAsATemporaryFile() throws {
        let (s, calls) = server()
        _ = s.handle(call("device", ["action": "push", "bundle": "dev.x", "payload": ["aps": ["alert": "Hi"]]]))
        let path = try #require(calls.argv.first?.last)
        #expect(path.hasSuffix(".json") && !FileManager.default.fileExists(atPath: path))  // removed after the call
    }

    @Test func annotationsMatchWhatTheToolsDo() {
        let tools = Dictionary(uniqueKeysWithValues: MCPTools.definitions.map { ($0["name"]?.string ?? "", $0) })
        #expect(Set(tools.keys) == ["snapshot", "act", "screenshot", "logs", "app", "device", "doctor"])
        for name in ["snapshot", "screenshot", "logs"] {
            #expect(tools[name]?["annotations"]?["readOnlyHint"] == true, "\(name)")
            #expect(tools[name]?["description"]?.string?.contains("untrusted") == true, "\(name)")
        }
        for name in ["act", "app", "device"] {
            #expect(
                tools[name]?["annotations"]?["readOnlyHint"] == false
                    && tools[name]?["annotations"]?["destructiveHint"] == true, "\(name)")
        }
        #expect(
            tools["doctor"]?["annotations"]?["readOnlyHint"] == false
                && tools["doctor"]?["annotations"]?["destructiveHint"] == false)
        #expect(
            tools["app"]?["annotations"]?["openWorldHint"] == true
                && tools["act"]?["annotations"]?["openWorldHint"] == false)
        for (name, tool) in tools {
            #expect(
                tool["inputSchema"]?["type"] == "object" && tool["inputSchema"]?["additionalProperties"] == false,
                "\(name)")
            #expect(tool["inputSchema"]?["properties"]?["udid"] != nil, "\(name)")
        }
    }

    @Test func screenshotsComeBackInline() {
        let (s, _) = server(Output("screenshot → /tmp/s.jpg · 402×874 px · 1 px = 1 pt", data: ["path": "/tmp/s.jpg"]))
        let content = s.handle(call("screenshot", [:]))?["result"]?["content"]?.array ?? []
        #expect(content.count == 2)
        #expect(content.last == ["type": "image", "data": "/9g=", "mimeType": "image/jpeg"])
    }

    @Test func cancelledRequestsGetNoAnswer() {
        let inbox = MCPInbox()
        inbox.push(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}}"#.utf8))
        inbox.push(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#.utf8))
        inbox.close()
        #expect(inbox.next() != nil)  // the request is still taken…
        #expect(inbox.isCancelled(7) && !inbox.isCancelled(8))  // …but its answer is dropped
        #expect(inbox.next() == nil)
    }

    @Test func logsAcceptsSinceLastWithACount() {
        let (s, calls) = server()
        _ = s.handle(call("logs", ["since_last": true, "last": 40]))
        #expect(calls.argv.last == ["logs", "--since-last", "--last", "40"])
    }

    @Test func instructionsSayWhenToLookAtPixels() {
        #expect(MCPServer.instructions.contains("Take a screenshot to check how something looks"))
    }
}
