import Foundation
import Testing
@testable import ChauffeurCore

@Suite struct AXSettingsTests {
    /// `simctl spawn <udid> defaults read com.apple.Accessibility` after an Xcode 27 session ended.
    static let afterXcode = """
        {
            AccessibilityEnabled = 0;
            ApplicationAccessibilityEnabled = 0;
            AutomationEnabled = 0;
            ReduceMotionEnabled = 0;
        }
        """

    @Test func flagsThatAreOffOrMissing() {
        #expect(AXSettings.off(Self.afterXcode) == ["ApplicationAccessibilityEnabled", "AutomationEnabled"])
        #expect(AXSettings.off("{\n    ApplicationAccessibilityEnabled = 1;\n    AutomationEnabled = 1;\n}") == [])
        #expect(AXSettings.off("{\n    AutomationEnabled = 1;\n}") == ["ApplicationAccessibilityEnabled"])
        #expect(AXSettings.off("") == ["ApplicationAccessibilityEnabled", "AutomationEnabled"])
    }

    /// The general flag does not gate the tree (tested 2026-10-07), so chauffeur leaves the user's setting alone.
    @Test func theGeneralAccessibilityFlagIsNotTouched() {
        #expect(!AXSettings.flags.contains("AccessibilityEnabled"))
    }
}
