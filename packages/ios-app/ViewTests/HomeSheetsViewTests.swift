import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeSheetsViewTests: ShuffledTestCase {
    func testWorkerRowsUseStandardSubtext() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            try await openTasks(app)
            try await app.activate("home-task-active")
            try await app.until("the worker detail") { app.element("home-task-detail") != nil }
            try await app.expandTopSheet()
            let ids = ["home-task-model-title", "home-task-model-subtext", "home-task-subagents-subtext", "home-task-spend-subtext",
                       "home-task-run-run-live-subtext", "home-task-checkin-done-subtext", "home-task-checkin-next-subtext"]
            try await app.until("the worker rows") { ids.allSatisfy { app.element($0) != nil } }
            let lineHeight = app.element("home-task-model-title")!.accessibilityFrame.height
            XCTAssertGreaterThan(lineHeight, 0)
            for id in ["home-task-model", "home-task-subagents", "home-task-spend", "home-task-run-run-live"] {
                XCTAssertEqual(app.element("\(id)-subtext")!.accessibilityFrame.height, lineHeight, accuracy: 0.25,
                               "\(id) matches the approved subheadline reading size")
            }
            XCTAssertEqual(app.element("home-task-checkin-done-subtext")!.accessibilityFrame.height, lineHeight, accuracy: 0.25,
                           "Latest check-in Done uses the approved subheadline size of the single-line Worker values")
            XCTAssertEqual(app.element("home-task-checkin-next-subtext")!.accessibilityFrame.height, lineHeight, accuracy: 0.25,
                           "Latest check-in Next uses the approved subheadline size of the single-line Worker values")
        }
    }

    func testTaskCardsKeepBalancedInsetsAndMemoryRowsIntact() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-task-padding-review"]) { app in
            try await openManageHome(app)
            try await openTasks(app)
            for id in ["active", "terminal"] {
                let ids = ["home-task-card-\(id)-container", "home-task-\(id)-title", "home-task-\(id)-status", "home-task-\(id)-metadata"]
                try await app.until("the \(id) card") { ids.allSatisfy { app.element($0) != nil } }
                let card = app.element(ids[0])!.accessibilityFrame, title = app.element(ids[1])!.accessibilityFrame
                let status = app.element(ids[2])!.accessibilityFrame, footer = app.element(ids[3])!.accessibilityFrame
                XCTAssertEqual(min(title.minY, status.minY) - card.minY, card.maxY - footer.maxY, accuracy: 0.5,
                               "The painted card, not just its button's AX frame, has balanced insets")
            }
            try await app.activate("home-sheet-done-tasks")
            try await app.until("Manage Home returns") { app.element("home-manage-memory-browser") != nil && app.element("home-sheet-done-tasks") == nil }
            _ = try await revealed(app, "home-manage-memory-browser")
            try await app.activate("home-manage-memory-browser")
            try await app.until("Memory opens") { app.element("home-memory-row-39") != nil }
            try await app.expandTopSheet()
            let ids = ["home-memory-card-39-container", "home-memory-row-39-title", "home-memory-row-39-metadata"]
            try await app.until("the memory row") { ids.allSatisfy { app.element($0) != nil } }
            let card = app.element(ids[0])!.accessibilityFrame, title = app.element(ids[1])!.accessibilityFrame
            let footer = app.element(ids[2])!.accessibilityFrame
            XCTAssertEqual(title.minY - card.minY, card.maxY - footer.maxY, accuracy: 0.5, "The shared row still hugs a Memory preview and its metadata")
            try await app.activate("home-memory-row-39")
            try await app.until("Memory row navigation remains intact") { app.element("home-memory-detail") != nil }
        }
    }

    func testManageHomeMemoryAndChapterCountValues() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-memory-boundary-regression"]) { app in
            try await openManageHome(app)
            try await app.until("the memory and chapter rows") {
                app.element("home-manage-memory-browser") != nil && app.element("home-manage-chapters") != nil
            }
            XCTAssertTrue(app.element("home-manage-memory-browser")?.accessibilityLabel?.contains("40 messages · 11 lines in view") == true)
            XCTAssertTrue(app.element("home-manage-chapters")?.accessibilityLabel?
                .contains("2 chapters · Active chapter 22% of soft limit") == true)
        }
    }

    func testCheckinUsesCompactSpacingAndStandardSubtext() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                              + (dark ? ["-home-dark", "-settings-dark"] : []), theme: .burgundy) { app in
                try await openManageHome(app)
                try await openTasks(app)
                try await app.activate("home-task-active")
                try await app.until("the worker detail") { app.element("home-task-detail") != nil }
                try await app.expandTopSheet()
                _ = try await revealed(app, "home-task-checkin")
                _ = try await revealed(app, "home-task-checkin-next")
                let ids = ["home-task-checkin-summary-title", "home-task-checkin-summary-subtext", "home-task-checkin-done-title",
                           "home-task-checkin-done-subtext", "home-task-checkin-next-title", "home-task-checkin-timestamp-title",
                           "home-task-view-checkins"]
                try await app.until("the check-in rows") { ids.allSatisfy { app.element($0) != nil } }
                let meta = app.element("home-task-checkin-summary-subtext")!.accessibilityFrame
                let standard = app.element("home-task-checkin-timestamp-title")!.accessibilityFrame
                XCTAssertEqual(meta.height, standard.height, accuracy: 0.25, "Context uses the same shared subtext token as the timestamp")
                XCTAssertLessThanOrEqual(app.element("home-task-checkin-next-title")!.accessibilityFrame.minY
                                            - app.element("home-task-checkin-done-subtext")!.accessibilityFrame.maxY, 12,
                                         "Adjacent check-in blocks use shared section/line spacing, not full row insets twice")
                let viewAll = try await revealed(app, "home-task-view-checkins")
                let subtitle = try XCTUnwrap(MountedFixture.elements(in: app.top).last { node in
                    node.accessibilityLabel == "Every operation and resume" && !node.accessibilityTraits.contains(.button)
                        && viewAll.accessibilityFrame.contains(CGPoint(x: node.accessibilityFrame.midX, y: node.accessibilityFrame.midY))
                }, app.tree())
                XCTAssertEqual(subtitle.accessibilityFrame.height, meta.height, accuracy: 0.5)
            }
        }
    }

    func testMemoryBoundaryBalancesCardGaps() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                              + (dark ? ["-home-dark", "-settings-dark"] : []), theme: .burgundy) { app in
                try await openManageHome(app)
                _ = try await revealed(app, "home-manage-memory-browser")
                try await app.activate("home-manage-memory-browser")
                try await app.until("Memory opens") { app.element("home-sheet-done-memory") != nil }
                try await app.expandTopSheet()
                _ = try await revealed(app, "home-memory-resolution-boundary")
                let ids = ["home-memory-boundary-title", "home-memory-boundary-subtext", "home-memory-card-34-container", "home-memory-card-32-container"]
                try await app.until("the boundary and its cards") { ids.allSatisfy { app.element($0) != nil } }
                let above = app.element("home-memory-card-34-container")!.accessibilityFrame
                let below = app.element("home-memory-card-32-container")!.accessibilityFrame
                let firstLine = app.element("home-memory-boundary-title")!.accessibilityFrame
                let lastLine = app.element("home-memory-boundary-subtext")!.accessibilityFrame
                XCTAssertEqual(firstLine.minY - above.maxY, below.minY - lastLine.maxY, accuracy: 1,
                               "The separator's explanatory copy has equal air between the cards on both sides")
            }
        }
    }

    private func openTasks(_ app: MountedFixture) async throws {
        _ = try await revealed(app, "home-manage-tasks")
        try await app.activate("home-manage-tasks")
        try await app.until("Tasks opens") { app.element("home-task-active") != nil }
        try await app.expandTopSheet()
    }
}
