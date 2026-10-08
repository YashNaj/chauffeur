import Testing
@testable import ChauffeurCore

@Suite struct ArgsTests {
    @Test func optionsAndFlagsMayFollowPositionals() throws {
        var a = try Args(["Sign in", "--timeout", "5", "--gone"], flags: ["--gone"], options: ["--timeout"], usage: "u")
        #expect(a.option("--timeout") == "5" && a.flag("--gone"))
        let first = a.next(), second = a.next()
        #expect(first == "Sign in" && second == nil)
    }

    @Test func everythingAfterDoubleDashIsData() throws {
        var a = try Args(["e2", "--submit", "--", "--submit", "--all"], flags: ["--submit"], usage: "u")
        let ref = a.next(), text = a.text()
        #expect(a.flag("--submit") && ref == "e2" && text == "--submit --all")
    }

    @Test func unknownOptionsMissingValuesAndRepeatsAreUsageErrors() {
        #expect(throws: ChauffeurError.usage("unknown option --lnog\nu")) { try Args(["e4", "--lnog", "1"], options: ["--long"], usage: "u") }
        #expect(throws: ChauffeurError.usage("--long needs a value\nu")) { try Args(["e4", "--long"], options: ["--long"], usage: "u") }
        #expect(throws: ChauffeurError.usage("--in is given twice\nu")) { try Args(["--in", "e1", "--in", "e2"], options: ["--in"], usage: "u") }
    }

    @Test func numbersAreValidatedNotDefaulted() throws {
        #expect(try Args(["--timeout", "2.5"], options: ["--timeout"], usage: "u").number("--timeout", in: 0...300) == 2.5)
        #expect(try Args([], options: ["--timeout"], usage: "u").number("--timeout", in: 0...300) == nil)
        for bad in ["soon", "-1", "nan", "1e999"] {
            let a = try Args(["--timeout", bad], options: ["--timeout"], usage: "u")
            #expect(throws: ChauffeurError.self) { try a.number("--timeout", in: 0...300) }
        }
        let last = try Args(["--last", "2.5"], options: ["--last"], usage: "u")
        #expect(throws: ChauffeurError.self) { try last.integer("--last", in: 1...500) }
    }

    @Test func singleDashTokensAreData() throws {
        var a = try Args(["-5", "-UITesting"], usage: "u")
        #expect(a.text() == "-5 -UITesting")
    }

    @Test func restOptionTakesEverythingAfterIt() throws {
        var a = try Args(["com.example", "--args", "--json", "--", "-seed", "4"], restOption: "--args", usage: "u")
        let bundle = a.next()
        #expect(bundle == "com.example" && a.rest == ["--json", "--", "-seed", "4"])
    }

    @Test func leftoverPositionalsAreRejected() throws {
        var a = try Args(["e4", "e5"], usage: "u")
        _ = a.next()
        #expect(throws: ChauffeurError.usage("unexpected argument \"e5\"\nu")) { try a.done() }
    }

    @Test func usageListsEveryCommand() {
        for command in ["use", "doctor", "snapshot", "find", "wait", "tap", "type", "scroll", "install", "launch", "terminate"] {
            #expect(Usage.text.contains("\n  \(command) "))
        }
    }
}
