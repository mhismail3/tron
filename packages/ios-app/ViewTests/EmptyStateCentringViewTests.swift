import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class EmptyStateCentringViewTests: ShuffledTestCase {
    func testEmptySubagentHistoryCentresItsPlaceholder() async throws {
        try await mounted(["-tron-subagent-parity-fixture", "-history-grouping", "-history-empty", "-light"]) { app in
            try await app.activate("Subagent History")
            try await assertCentredEmptyState(app, title: "Subagent History", placeholder: "No recorded subagents",
                                              viewport: "process-history-feed", caption: "Newest first")
        }
    }

    func testEmptyFeedSheetsCentreTheirPlaceholders() async throws {
        try await mounted(["-tron-session-configuration-fixture", "-history-empty", "-fixture-appearance", "light"]) { app in
            try await app.activate("Stop session")
            _ = try await revealed(app, "Session History")
            try await app.activate("Session History")
            try await assertCentredEmptyState(app, title: "Session History", placeholder: "No history yet",
                                              viewport: "session-history-viewport", caption: "All branches")
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-profile-empty",
                           "-home-browser-empty", "-home-sheet-tasks-empty"]) { app in
            try await openManageHome(app)
            for (row, title, placeholder, viewport, caption, done) in [
                ("home-manage-profile", "Profile", "Nothing learned yet", "home-profile-viewport", "About you, organized by area", "home-sheet-done-profile"),
                ("home-manage-memory-browser", "Memory", "No memory yet", "home-memory-viewport", "Newest first", "home-sheet-done-memory"),
                ("home-manage-tasks", "Tasks", "No tasks", "home-tasks-viewport", "Newest first", "home-sheet-done-tasks"),
            ] {
                _ = try await revealed(app, row)
                try await app.activate(row)
                try await assertCentredEmptyState(app, title: title, placeholder: placeholder, viewport: viewport, caption: caption)
                try await app.activate(done)
                try await app.until("Manage Home returns") { app.element(done) == nil && app.element(row) != nil }
            }
        }
    }

    private func assertCentredEmptyState(_ app: MountedFixture, title: String, placeholder text: String,
                                         viewport: String, caption captionText: String) async throws {
        func prefixed(_ prefix: String) -> NSObject? {
            MountedFixture.elements(in: app.top).last { $0.isAccessibilityElement && $0.accessibilityLabel?.hasPrefix(prefix) == true }
        }
        func feed() -> UIScrollView? {
            MountedFixture.views(UIScrollView.self, in: app.top).last { MountedFixture.identifier($0) == viewport }
        }
        try await app.until("\(title) shows its placeholder, viewport and caption") {
            prefixed(text) != nil && feed() != nil && prefixed(captionText) != nil
        }
        for detent in ["medium", "large"] {
            if detent == "large" { try await app.expandTopSheet() }
            _ = try await app.still("\(title) at \(detent) layout") {
                guard let p = prefixed(text), let f = feed(), let c = prefixed(captionText) else { return nil }
                let feedFrame = f.convert(f.bounds, to: nil)
                return [p.accessibilityFrame.midY, c.accessibilityFrame.maxY, feedFrame.maxY].map { Double($0) / 1000 }
            }
            let placeholder = prefixed(text)!.accessibilityFrame, caption = prefixed(captionText)!.accessibilityFrame
            let feedFrame = feed()!.convert(feed()!.bounds, to: nil)
            let visibleBottom = min(feedFrame.maxY, app.window.bounds.maxY)
            let centre = (caption.maxY + visibleBottom) / 2
            XCTAssertEqual(placeholder.midY, centre, accuracy: 24,
                           "\(title) at \(detent): the placeholder centres between the caption (\(caption.maxY)) and the sheet bottom (\(visibleBottom))")
            XCTAssertEqual(placeholder.midX, app.window.bounds.midX, accuracy: 4,
                           "\(title) at \(detent): the placeholder centres horizontally")
        }
    }
}
