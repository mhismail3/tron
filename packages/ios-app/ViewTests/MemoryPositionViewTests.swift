import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class MemoryPositionViewTests: ShuffledTestCase {
    func testScopedMemoryAccessibility() async throws { try await journey() }

    func testPagedMemoryAndTasksLabelLoadedItems() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-paging", "-home-browser-paging"]) { app in
            try await openManageHome(app)
            for (row, title, viewport, done) in [
                ("home-manage-memory-browser", "Memory", "home-memory-viewport", "home-sheet-done-memory"),
                ("home-manage-tasks", "Tasks", "home-tasks-viewport", "home-sheet-done-tasks")
            ] {
                _ = try await revealed(app, row)
                try await app.activate(row)
                try await app.until("\(title) opens") { app.element(done) != nil }
                try await app.waitForTopSheetToSettle()
                try await scrolled(app, viewport)
                let label = try await positionChip(app).accessibilityLabel ?? ""
                XCTAssertTrue(label.hasPrefix("Items "), label)
                if title == "Memory" {
                    XCTAssertTrue(label.contains("of at least 10"), label)
                }
                try await app.activate(done)
            }
        }
    }

    private func journey() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-memory-position-regression",
                           "-AppleLanguages", "(en)", "-AppleLocale", "en_US"], contentSize: .accessibilityExtraExtraExtraLarge) { app in
            try await app.activate("home-pinned-row")
            try await app.activate("session-context-button")
            try await app.until("Manage Home opens") { app.element("home-manage-state") != nil }
            _ = try? await app.waitForTopSheetToSettle()
            _ = try await revealed(app, "home-manage-chapters")
            try await app.activate("home-manage-chapters")
            try await app.until("Chapters opens") { app.element("home-chapter-1") != nil }
            _ = try? await app.waitForTopSheetToSettle()
            try await app.activate("home-chapter-1")
            try await app.until("the chapter opens") { app.element("home-chapter-detail") != nil }
            _ = try? await app.waitForTopSheetToSettle()
            _ = try await revealed(app, "home-chapter-browse-memory")
            XCTAssertNil(app.element("From Home's summaries of this chapter."),
                         "Topics already names the chapter summaries; no redundant caption can scroll behind Chapters")
            try await app.activate("home-chapter-browse-memory")
            try await app.until("the scoped memory opens") { app.element("home-memory-summary-7672-8") != nil }
            _ = try? await app.waitForTopSheetToSettle()
            try await checkChip(app, count: 32)
            try await app.activate("home-sheet-done-memory")
            try await app.activate("home-sheet-done-chapter")
            try await app.activate("home-sheet-done-chapters")
            _ = try await revealed(app, "home-manage-memory-browser")
            try await app.activate("home-manage-memory-browser")
            try await app.until("the unscoped memory opens") { app.element("home-memory-summary-7736-8") != nil }
            _ = try? await app.waitForTopSheetToSettle()
            try await checkChip(app, count: 40)
        }
    }

    private func checkChip(_ app: MountedFixture, count: Int) async throws {
        try await scrolled(app, "home-memory-viewport")
        let chip = try await positionChip(app)
        let label = chip.accessibilityLabel ?? ""
        let numbers = label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        XCTAssertTrue(label.hasPrefix("Items "), label)
        XCTAssertEqual(numbers.count, 3, label)
        if numbers.count == 3 {
            XCTAssertEqual(numbers[2], count, "Total counts this list's rows, never catalog messages")
            XCTAssertTrue((1...count).contains(numbers[0]) && (numbers[0]...count).contains(numbers[1]), label)
        }
        XCTAssertGreaterThanOrEqual(chip.accessibilityFrame.height, 44)
        XCTAssertLessThanOrEqual(chip.accessibilityFrame.width, app.window.bounds.width - 32)
        try await app.activate("feed-position-chip")
    }

    private func positionChip(_ app: MountedFixture) async throws -> NSObject {
        var chip: NSObject?
        try await app.until("the position chip") {
            chip = app.element("feed-position-chip")
            return chip != nil
        }
        return try XCTUnwrap(chip)
    }

}

@MainActor
func scrolled(_ app: MountedFixture, _ key: String) async throws {
    guard let scroll = MountedFixture.views(UIScrollView.self, in: app.top).last(where: { MountedFixture.identifier($0) == key }) else {
        throw FixtureNotReady(description: "\(key) is not a scroll view on screen\n\(app.tree())")
    }
    let maximum = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
    let offset = min(scroll.contentOffset.y + scroll.bounds.height * 0.8, maximum)
    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
    await MountedFixture.nextFrame()
    await MountedFixture.nextFrame()
}
