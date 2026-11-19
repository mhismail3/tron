import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class TaskToolOutcomeViewTests: ShuffledTestCase {
    func testRenameStopFallbackAndErrorUseTheirRecordedOutcomes() async throws {
        for scenario in ["task-rename", "task-stop", "task-fallback", "task-malformed", "task-refused"] {
            try await mounted(["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                               "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
                try await app.until("the \(scenario) sheet") { app.element("Technical details") != nil }
                if ["task-fallback", "task-malformed"].contains(scenario) {
                    XCTAssertNil(app.element("home-tool-detail"), "Unknown or malformed results must retain the generic detail")
                    return
                }
                try await app.until("the custom detail") { app.element("home-tool-detail") != nil }
                if scenario == "task-rename" {
                    let node = try await revealed(app, "home-tool-row-New title")
                    let label = (app.element("home-tool-row-New title") ?? node).accessibilityLabel ?? ""
                    XCTAssertTrue(label.contains("Photo preparation: ready for review"), label)
                } else if scenario == "task-stop" {
                    XCTAssertTrue(MountedFixture.elements(in: app.top).contains {
                        let label = $0.accessibilityLabel ?? ""
                        return !$0.accessibilityTraits.contains(.button) && (label == "Stop recorded for this exact operation."
                            || label.hasPrefix("Stop recorded for this exact operation., "))
                    }, app.tree())
                    XCTAssertNil(app.element("home-tool-text-message"))
                } else {
                    let failure = try XCTUnwrap(app.element("home-tool-failure"), app.tree()).accessibilityFrame
                    XCTAssertTrue(MountedFixture.elements(in: app.top).contains {
                        failure.contains(CGPoint(x: $0.accessibilityFrame.midX, y: $0.accessibilityFrame.midY))
                            && $0.accessibilityLabel?.contains("Use resume to continue it in place.") == true
                    }, app.tree())
                }
            }
        }
    }
}
