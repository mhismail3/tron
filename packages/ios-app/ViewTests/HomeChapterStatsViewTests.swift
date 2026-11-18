import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeChapterStatsViewTests: ShuffledTestCase {
    func testChapterStatsBelongToBothSummaryHeaders() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-chapters")
            try await app.activate("home-manage-chapters")
            try await app.until("Chapters opens") { app.element("home-chapter-list") != nil }
            try await app.expandTopSheet()
            for ordinal in [2, 1] {
                try await app.activate("home-chapter-\(ordinal)")
                try await app.until("chapter \(ordinal) opens") {
                    app.element("home-chapter-detail") != nil && app.element("home-chapter-stats") != nil
                        && app.element("home-chapter-size") != nil && app.element("home-chapter-header") != nil
                }
                try await app.expandTopSheet()
                let header = app.element("home-chapter-header")!.accessibilityFrame
                let size = app.element("home-chapter-size")!.accessibilityFrame
                let stats = app.element("home-chapter-stats")!.accessibilityFrame
                let tags = MountedFixture.elements(in: app.top).filter { node in
                    node.isAccessibilityElement && !(node.accessibilityLabel ?? "").isEmpty
                        && !node.accessibilityTraits.contains(.button)
                        && stats.contains(CGPoint(x: node.accessibilityFrame.midX, y: node.accessibilityFrame.midY))
                }
                XCTAssertEqual(tags.count, 3, "Chapter \(ordinal) stats: \(tags.map { $0.accessibilityLabel ?? "" })\n\(app.tree())")
                for phrase in ["user message", "Home repl", "task"] {
                    XCTAssertTrue(tags.contains { $0.accessibilityLabel?.contains(phrase) == true }, "Chapter \(ordinal) misses \(phrase)")
                }
                XCTAssertGreaterThanOrEqual(stats.minY, size.maxY)
                XCTAssertLessThanOrEqual(stats.maxY, header.maxY)
                for tag in tags {
                    XCTAssertGreaterThanOrEqual(tag.accessibilityFrame.minX, header.minX)
                    XCTAssertLessThanOrEqual(tag.accessibilityFrame.maxX, header.maxX)
                }
                try await app.activate("home-sheet-done-chapter")
                try await app.until("Chapters returns") { app.element("home-chapter-detail") == nil && app.element("home-chapter-list") != nil }
            }
        }
    }
}
