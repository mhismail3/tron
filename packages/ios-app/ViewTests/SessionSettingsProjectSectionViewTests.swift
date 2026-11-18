import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SessionSettingsProjectSectionViewTests: ShuffledTestCase {
    func testSessionSettingsShowsProjectSection() async throws {
        try await mounted(["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                           "-fixture-appearance", "light"]) { app in
            try await app.activate("Stop session")
            try await app.until("Manage Session opens") { app.element("session-usage-summary") != nil }
            try await app.expandTopSheet()
            _ = try await revealed(app, "chat-settings-link")
            try await app.activate("chat-settings-link")
            try await app.until("Session Settings opens") { app.navigationTitle("Session Settings") != nil }
            try await app.expandTopSheet()
            try await app.until("the project section") {
                app.element("session-project-settings") != nil && app.element("project-settings-no-overrides") != nil
            }
            let noneNode = try await revealed(app, "project-settings-no-overrides")
            let section = app.element("session-project-settings")!.accessibilityFrame
            @MainActor func inside(_ area: CGRect) -> [NSObject] {
                MountedFixture.elements(in: app.top).filter { area.contains(CGPoint(x: $0.accessibilityFrame.midX, y: $0.accessibilityFrame.midY)) }
            }
            let none = app.element("project-settings-no-overrides")?.accessibilityFrame ?? noneNode.accessibilityFrame
            XCTAssertTrue(inside(none).contains { $0.accessibilityLabel?.contains("No repository overrides") == true }, app.tree())
            XCTAssertLessThan(none.height, 140, "No repository overrides is a row: \(none)")
            XCTAssertTrue(inside(section).contains {
                MountedFixture.identifier($0) == "project-settings-trust" && $0.accessibilityTraits.contains(.button)
            }, app.tree())
            XCTAssertTrue(inside(section).filter { $0.accessibilityLabel?.contains("Workspace") == true }.isEmpty,
                          "Manage Session's Workspace row already names the branch")
            XCTAssertEqual(Set(MountedFixture.elements(in: app.top).filter {
                MountedFixture.identifier($0) == "settings-ignored-defaultTools"
            }.map { ObjectIdentifier($0) }).count, 1)
        }
    }
}
