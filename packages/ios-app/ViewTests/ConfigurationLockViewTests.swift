import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ConfigurationLockViewTests: ShuffledTestCase {
    func testLockedThinkingIsDisabledWithItsReasonSoNoEditIsDropped() async throws {
        let reason = "Stop the session before changing its configuration."
        try await mounted(["-tron-session-configuration-fixture"]) { app in
            try await app.activate("Manage running session")
            var control: NSObject?
            try await app.until("Thinking is shown") {
                control = app.element("settings-choice-control")
                return control != nil
            }
            XCTAssertTrue(control?.accessibilityTraits.contains(.notEnabled) == true,
                          "A locked Thinking edit could never be saved, so the slider must not open\n\(app.tree())")
            XCTAssertEqual(control?.accessibilityHint, reason, "The row says why it is locked\n\(app.tree())")
        }
    }
}
