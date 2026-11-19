import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class TaskToolReaderOwnershipViewTests: ShuffledTestCase {
    func testTaskResumeStopAndNoMessageKeepIdentityAndReaderOwnership() async throws {
        for (scenario, expected) in [
            ("task-resume-message", "Instruction (The task continues in place in its worker session.)"),
            ("task-stop-message", "Message (Stop recorded for this exact operation.)"),
            ("task-stop-empty", "Stop recorded for this exact operation.")
        ] {
            try await mounted(["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario]) { app in
                @MainActor func text(_ value: String) -> Bool {
                    MountedFixture.elements(in: app.top).contains {
                        let label = $0.accessibilityLabel ?? ""
                        return !$0.accessibilityTraits.contains(.button) && (label == value || label.hasPrefix("\(value), "))
                    }
                }
                try await app.until("the \(scenario) detail") { app.element("home-tool-detail") != nil }
                XCTAssertNil(app.element("home-tool-row-Task ID"))
                let header = try XCTUnwrap(app.element("home-tool-header")).accessibilityFrame
                XCTAssertTrue(MountedFixture.elements(in: app.top).contains {
                    header.contains(CGPoint(x: $0.accessibilityFrame.midX, y: $0.accessibilityFrame.midY))
                        && $0.accessibilityLabel?.contains("photo-readiness") == true
                }, app.tree())
                XCTAssertTrue(text(expected), app.tree())
                if scenario == "task-stop-empty" {
                    XCTAssertNil(app.element("home-tool-text-message-view-all"))
                    XCTAssertNil(app.element("home-tool-text-message"))
                    return
                }
                let reader = try await revealed(app, "home-tool-text-message-view-all")
                XCTAssertEqual((app.element("home-tool-text-message-view-all") ?? reader).accessibilityLabel, "View full message")
                try await app.activate("home-tool-text-message-view-all")
                try await app.until("the full reader") { app.element("home-reading-text") != nil }
                XCTAssertTrue(MountedFixture.elements(in: app.top).contains {
                    $0.accessibilityLabel?.contains("Wait for visual approval") == true
                }, app.tree())
                try await app.activate("Done")
                try await app.until("the delivery summary returns") { app.element("home-reading-text") == nil && text(expected) }
            }
        }
    }
}
