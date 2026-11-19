import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeTaskReadingViewTests: ShuffledTestCase {
    func testTaskReadingSubtextLight() async throws { try await exercise([]) }

    private func exercise(_ arguments: [String]) async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-task-padding-review"] + arguments) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-controls")
            try await app.until("the Controls row markers") {
                app.element("home-manage-controls-title") != nil && app.element("home-manage-controls-subtext") != nil
            }
            let metadata = app.element("home-manage-controls-subtext")!, settingsTitle = app.element("home-manage-controls-title")!
            let metadataHeight = metadata.accessibilityFrame.height
            XCTAssertGreaterThan(metadataHeight, 0)
            XCTAssertLessThan(metadataHeight, settingsTitle.accessibilityFrame.height, "Default shared-row callers keep their smaller metadata style")
            _ = try await revealed(app, "home-manage-tasks")
            try await app.activate("home-manage-tasks")
            try await app.until("Tasks opens") { app.element("home-task-terminal") != nil }
            try await app.expandTopSheet()
            _ = try await revealed(app, "home-task-terminal")
            try await app.activate("home-task-terminal")
            try await app.until("the task opens") { app.element("home-task-detail") != nil }
            try await app.expandTopSheet()
            let ids = ["home-task-model-title", "home-task-result-subtext", "home-task-model-subtext", "home-task-subagents-subtext",
                       "home-task-spend-subtext", "home-task-checkin-summary-title", "home-task-checkin-done-subtext",
                       "home-task-checkin-next-subtext", "home-task-checkin-next"]
            try await app.until("the reading rows") { ids.allSatisfy { app.element($0) != nil } }
            let lineHeight = app.element("home-task-model-title")!.accessibilityFrame.height
            XCTAssertGreaterThan(lineHeight, 0)
            for id in ["home-task-result", "home-task-model", "home-task-subagents", "home-task-spend"] {
                XCTAssertEqual(app.element("\(id)-subtext")!.accessibilityFrame.height, lineHeight, accuracy: 0.25,
                               "\(id) uses the approved reading size, not metadata")
            }
            let checkinHeight = ["home-task-checkin-summary-title", "home-task-checkin-done-subtext", "home-task-checkin-next-subtext"]
                .map { app.element($0)!.accessibilityFrame.height }.reduce(0, +)
            XCTAssertGreaterThan(checkinHeight / lineHeight, 4.5, "The long check-in wraps to at least five lines without the default two-line cap")
            XCTAssertTrue(app.element("home-task-checkin-next")!.accessibilityLabel?.contains("report the remaining scope") == true,
                          "The complete check-in, including its final Next instruction, remains available")
        }
    }
}
