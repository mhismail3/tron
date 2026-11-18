import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ManageSessionReviewViewTests: ShuffledTestCase {
    func testManageSessionLayout() async throws {
        try await mounted(["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                           "-fixture-appearance", "light"]) { app in
            try await app.activate("Stop session")
            try await app.until("Manage Session opens") { app.element("session-usage-summary") != nil }
            try await app.expandTopSheet()
            @MainActor func button(_ key: String) -> NSObject? {
                MountedFixture.elements(in: app.top).last {
                    (MountedFixture.identifier($0) == key || $0.accessibilityLabel == key) && $0.accessibilityTraits.contains(.button)
                }
            }
            @MainActor func labels(containing text: String) -> [NSObject] {
                MountedFixture.elements(in: app.top).filter { $0.accessibilityLabel?.contains(text) == true }
            }
            try await app.until("the usage card") {
                app.element("session-usage-headline") != nil && app.element("session-usage-detail") != nil
                    && button("manage-session-compact") != nil
            }
            let card = app.element("session-usage-summary")!.accessibilityFrame
            let headline = app.element("session-usage-headline")!.accessibilityFrame
            let detailNode = app.element("session-usage-detail")!, detail = detailNode.accessibilityFrame
            let compact = button("manage-session-compact")!.accessibilityFrame
            XCTAssertEqual(detailNode.accessibilityLabel, "311K/1M • 31% used")
            XCTAssertEqual(detail.minX, headline.minX, accuracy: 1, "the usage line is left-aligned under the headline")
            XCTAssertGreaterThanOrEqual(detail.minY, headline.maxY - 1, "the usage line is below the headline")
            XCTAssertTrue(card.contains(compact), "Compact Now is inside the usage card: \(compact) vs \(card)")
            XCTAssertGreaterThan(compact.minX, max(headline.maxX, detail.maxX), "Compact Now trails both lines")
            XCTAssertEqual(compact.midY, (headline.minY + detail.maxY) / 2, accuracy: 1.5, "Compact Now is centered on both lines")
            XCTAssertTrue(labels(containing: "Compact conversation").isEmpty, "no separate Compact row")
            XCTAssertNotNil(button("manage-session-rename"), "the edit pencil stays")
            for title in ["Workspace", "Instructions"] {
                XCTAssertNotNil(button(title), "\(title) row\n\(app.tree())")
            }
            for gone in ["Current Branch", "Agent Instructions", "Resources"] {
                XCTAssertTrue(labels(containing: gone).isEmpty, "\(gone) is renamed or removed")
            }
            XCTAssertNil(button("project-settings-link"), "Project Settings lives in the session list's Project sheet")
            let html = try await revealed(app, "session-export-html")
            XCTAssertTrue(html.accessibilityTraits.contains(.button))
            XCTAssertTrue(app.window.bounds.contains(app.element("session-export-html")!.accessibilityFrame), app.tree())
        }
    }
}
