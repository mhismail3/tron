import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SheetLayoutViewTests: ShuffledTestCase {
    func testHomeSettingsAreOnMainSheet() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-settings-scope-review"]) { app in
            try await app.activate("home-pinned-row")
            try await app.activate("session-context-button")
            _ = try await revealed(app, "home-manage-settings")
            try await app.activate("home-manage-settings")
            try await app.until("Home Settings opens") { app.navigationTitle("Home Settings") != nil }
            try await app.expandTopSheet()
            try await app.until("the inline rows") { app.element("settings-row-model.queue_role_worker_") != nil }
            XCTAssertNil(app.element("settings-section-model-open"), "Workers are edited on Home Settings")
            XCTAssertNil(app.element("settings-section-tools-open"), "The Tools setting is on Home Settings")
            XCTAssertNil(app.element("settings-section-advanced-open"), "Connection and approvals are on Home Settings")
            let nodes = MountedFixture.elements(in: app.top)
            for prefix in ["settings-row-model.queue_role_worker_", "settings-row-model.queue_role_subagent_", "settings-row-model.queue_role_background_",
                           "settings-row-tools.active", "settings-row-run.transport", "settings-row-run.retry.maxRetries"] {
                XCTAssertTrue(nodes.contains { node in
                    let id = MountedFixture.identifier(node) ?? ""
                    return id.hasPrefix(prefix) && !id.hasSuffix("-reset")
                }, "Inline setting \(prefix)\n\(app.tree())")
            }
            XCTAssertNotNil(app.element("Home's overrides of Global settings. Worker launch choices apply to new workers."))
            let row = app.element("settings-row-model.queue_role_worker_")!.accessibilityFrame
            let inside = MountedFixture.elements(in: app.top).filter { row.contains(CGPoint(x: $0.accessibilityFrame.midX, y: $0.accessibilityFrame.midY)) }
            XCTAssertTrue(inside.contains { $0.accessibilityLabel == "Overridden" }, app.tree())
            XCTAssertTrue(inside.contains { (MountedFixture.identifier($0) ?? "").hasSuffix("-reset") }, app.tree())
            let editor = try XCTUnwrap(inside.first { $0.accessibilityLabel == "Worker models" && $0.accessibilityTraits.contains(.button) }, app.tree())
            XCTAssertTrue(editor.accessibilityActivate())
            try await app.until("The existing deeper list editor still opens") { app.navigationTitle("Worker models") != nil }
        }
    }

    func testSessionCaptionFollowsUntitledSettingsCard() async throws {
        try await mounted(["-tron-session-configuration-fixture", "-settings-scope-review", "-fixture-appearance", "light"]) { app in
            try await app.activate("Stop session")
            _ = try await revealed(app, "chat-settings-link")
            try await app.activate("chat-settings-link")
            try await app.until("Session Settings opens") { app.navigationTitle("Session Settings") != nil }
            try await app.expandTopSheet()
            let caption = "Choices for this session. Revert an override to use Global settings."
            try await app.until("the session card") {
                app.element("settings-section-tools-open") != nil && app.element("project-settings-trust") != nil
                    && app.element(caption) != nil && app.element("Repository Overrides") != nil
            }
            XCTAssertFalse(MountedFixture.elements(in: app.top).contains {
                $0.accessibilityLabel == "Settings" && $0.accessibilityTraits.contains(.header)
            }, "No Settings heading above the session card")
            let tools = app.element("settings-section-tools-open")!.accessibilityFrame
            let trust = app.element("project-settings-trust")!.accessibilityFrame
            let footer = app.element(caption)!.accessibilityFrame
            XCTAssertGreaterThan(footer.minY, max(tools.maxY, trust.maxY), "The explanatory caption is the card's footer")
            XCTAssertLessThan(footer.minY, app.element("Repository Overrides")!.accessibilityFrame.minY,
                              "The footer belongs to session choices, not repository overrides")
        }
    }
}
