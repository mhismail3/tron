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

    private func openTasks(_ app: MountedFixture) async throws {
        _ = try await revealed(app, "home-manage-tasks")
        try await app.activate("home-manage-tasks")
        try await app.until("Tasks opens") { app.element("home-task-active") != nil }
        try await app.expandTopSheet()
    }
}
