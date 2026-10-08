import Foundation
import Testing

@testable import ChauffeurCore

@Suite struct TouchLogParserTests {
    static let destinations = """
        destinations are now {
            EC90C53F: (hitTest); contextID: 0xEC90C53F; clientPort: 0x4F0F,
            A214404D: (hitTest); contextID: 0xA214404D; clientPort: 0x1DA33; inheritedSceneHostSettings: <identifier: sceneID:dev.chauffeur.fixture-default; touchBehavior: foreground>,
            7B0AF3A1: (hitTest); contextID: 0x7B0AF3A1; clientPort: 0x4F0F,
            FC3B97C5: (touchStream|filterDetachedTouches); contextID: 0xFC3B97C5; clientPort: 0x4F0F
        }
        """
    static let streamDown =
        "Digitizer token: 0xFC3B97C5; down; move; subevents: [path: 0; {603, 690}; down; move; touchID: 0x1; {603, 690}]"
    static let appDown =
        "Digitizer token: 0xA214404D; down; move; sgp; behavior: foreground; subevents: [path: 0; {201, 230}; down; move; touchID: 0x1; {201, 230}]"
    static let appUp =
        "Digitizer token: 0xA214404D; move (not touching!); up; sgp; behavior: foreground; subevents: [path: 0; {201, 230}; move (not touching!); up; touchID: 0x1; {201, 230}]"
    static let springBoardDown =
        "Digitizer token: 0x819D95C8; down; move; sgp; subevents: [path: 0; {201, 30}; down; move; touchID: 0x2; {201, 30}]"

    @Test func tapIntoAnApp() {
        var p = TouchLogParser()
        #expect(p.consume(Self.destinations) == nil)
        let records = [Self.streamDown, Self.appDown, Self.appUp].compactMap { p.consume($0) }
        #expect(records.count == 3)
        #expect(records[1] == TouchRecord(context: "A214404D", point: Point(x: 201, y: 230)))
        #expect(p.evidence(records) == .app("dev.chauffeur.fixture"))
    }

    @Test func tapOnSpringBoard() {
        var p = TouchLogParser()
        _ = p.consume(Self.destinations)
        let records = [Self.streamDown, Self.springBoardDown].compactMap { p.consume($0) }
        #expect(p.evidence(records) == .system)
    }

    @Test func onlyTheTouchStreamIsNoEvidence() {
        var p = TouchLogParser()
        _ = p.consume(Self.destinations)
        let records = [Self.streamDown].compactMap { p.consume($0) }
        #expect(p.evidence(records) == .none)
        #expect(p.evidence([]) == .none)
    }

    @Test func ownersAreLearnedFromAnyMessage() {
        var p = TouchLogParser()
        _ = p.consume(
            "adding latent: <BKTouchDestination: 0x600000c62b50; (hitTest); contextID: 0xA214404D; clientPort: 0x1DA33; inheritedSceneHostSettings: <identifier: sceneID:com.apple.Preferences-default; touchBehavior: foreground>; externalReferences: 1>"
        )
        let r = p.consume(Self.appDown)!
        #expect(p.evidence([r]) == .app("com.apple.Preferences"))
    }

    @Test func levelStatusParsing() {
        #expect(BackBoardLevel.parse("Mode for 'com.apple.BackBoard'  INFO PERSIST_DEFAULT") == "info")
        #expect(BackBoardLevel.parse("Mode for 'com.apple.BackBoard'  DEFAULT PERSIST_DEFAULT") == "default")
        #expect(BackBoardLevel.parse("garbage") == nil)
    }

    @Test func priorLevelSurvivesACrashedDaemon() throws {
        #expect(PriorLevel.choose(saved: "info", current: "debug") == "info")
        #expect(PriorLevel.choose(saved: nil, current: "default") == "default")
        #expect(PriorLevel.choose(saved: nil, current: "debug") == "default")  // leftover from an unknown crash
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chauffeur-test-\(UUID().uuidString).level")
        PriorLevel.save("info", to: url)
        #expect(PriorLevel.load(url) == "info")
        PriorLevel.clear(url)
        #expect(PriorLevel.load(url) == nil)
    }
}
