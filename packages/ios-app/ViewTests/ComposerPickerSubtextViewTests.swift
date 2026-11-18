import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ComposerPickerSubtextViewTests: ShuffledTestCase {
    func testComposerPickerSecondaryTextMatchesManageHomeRow() async throws {
        for scenario in ["picker", "picker-alternate", "picker-query"] {
            try await mounted(["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario]) { app in
                let labels = scenario == "picker-alternate"
                    ? ["No skills found", "No prompts found"]
                    : [scenario == "picker-query" ? "No commands & prompts found" : "No commands found"]
                    + (scenario == "picker-query" ? ["· \"review\""] : [])
                let descriptions = scenario == "picker-alternate" ? 1 : 2
                @MainActor func descriptionMarkers() -> [NSObject] {
                    MountedFixture.elements(in: app.top).filter {
                        let id = MountedFixture.identifier($0) ?? ""
                        return id.hasPrefix("composer-resource-") && id.hasSuffix("-subtext")
                    }
                }
                @MainActor func text(_ label: String) -> NSObject? {
                    MountedFixture.elements(in: app.top).first {
                        $0.isAccessibilityElement && $0.accessibilityLabel == label && !$0.accessibilityTraits.contains(.button)
                    }
                }
                try await app.until("\(scenario): the picker texts and the reference subtext") {
                    app.element("picker-reference-subtext") != nil && labels.allSatisfy { text($0) != nil }
                        && descriptionMarkers().count == descriptions
                }
                let reference = app.element("picker-reference-subtext")!.accessibilityFrame
                for marker in descriptionMarkers() {
                    XCTAssertEqual(marker.accessibilityFrame.height, reference.height, accuracy: 0.5,
                                   "\(scenario): entry description \(MountedFixture.identifier(marker) ?? "") must match Manage Home subtext")
                }
                for label in labels {
                    XCTAssertEqual(text(label)!.accessibilityFrame.height, reference.height, accuracy: 0.5,
                                   "\(scenario): \(label) must match Manage Home subtext")
                }
            }
        }
    }
}
