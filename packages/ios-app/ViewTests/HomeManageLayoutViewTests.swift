import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeManageLayoutViewTests: ShuffledTestCase {
    func testRingAlignmentReviewLight() async throws { try await ringAlignment([]) }
    func testRingAlignmentReviewDark() async throws { try await ringAlignment(["-home-dark"]) }
    func testHomeSettingsCardsLight() async throws { try await homeSettingsCards([]) }
    func testHomeSettingsCardsDark() async throws { try await homeSettingsCards(["-home-dark"]) }

    private func ringAlignment(_ arguments: [String]) async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"] + arguments) { app in
            try await openManageHome(app)
            @MainActor func title() -> NSObject? {
                MountedFixture.elements(in: app.top).last { $0.accessibilityLabel == "969K tokens left" && !$0.accessibilityTraits.contains(.button) }
            }
            try await app.until("the context summary") {
                app.element("home-context-ring") != nil && app.element("home-context-detail") != nil && title() != nil
            }
            let ring = app.element("home-context-ring")!.accessibilityFrame
            let combined = title()!.accessibilityFrame.union(app.element("home-context-detail")!.accessibilityFrame)
            XCTAssertEqual(ring.midY, combined.midY, accuracy: 1.5, "The ring centers on title and subtext together, not only the title")
        }
    }

    private func homeSettingsCards(_ arguments: [String]) async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"] + arguments) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-settings")
            try await app.activate("home-manage-settings")
            try await app.until("Home Settings opens") { app.element("home-settings-content") != nil }
            try await app.expandTopSheet()
            try await app.until("the workers and tools rows") {
                app.element("settings-row-model.queue_role_worker_") != nil && app.element("settings-row-tools.active") != nil
            }
            for id in ["settings-section-model-open", "settings-section-tools-open", "settings-section-advanced-open"] {
                XCTAssertFalse(MountedFixture.elements(in: app.top).contains {
                    MountedFixture.identifier($0) == id && $0.accessibilityTraits.contains(.button)
                }, id)
            }
            let workers = app.element("settings-row-model.queue_role_worker_")!.accessibilityFrame
            let tools = app.element("settings-row-tools.active")!.accessibilityFrame
            XCTAssertLessThan(workers.minY, tools.minY)
            XCTAssertEqual(workers.minX, tools.minX, accuracy: 1)
            XCTAssertEqual(workers.width, tools.width, accuracy: 1)
        }
    }
}
