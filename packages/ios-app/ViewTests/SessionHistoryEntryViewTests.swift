import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SessionHistoryEntryViewTests: ShuffledTestCase {
    func testHistoryEntryUsesOneScrollAndClearsToolbar() async throws {
        try await mounted(["-tron-session-configuration-fixture", "-settings-scope-review", "-fixture-appearance", "light",
                           "-manage-session-review", "-history-large"]) { app in
            try await app.activate("Stop session")
            _ = try await revealed(app, "Session History")
            try await app.activate("Session History")
            try await app.until("the history row") { app.element("history-row-h-6732") != nil }
            try await app.waitForTopSheetToSettle()
            try await app.activate("history-row-h-6731")
            try await app.until("History Entry opens") {
                app.navigationTitle("History Entry") != nil && entryText(app) { $0.hasSuffix(" characters") } != nil
            }
            let title = try XCTUnwrap(app.navigationTitle("History Entry"))
            let done = try XCTUnwrap(app.toolbarActions(around: title).first { $0.accessibilityLabel == "Done" })
            let response = try XCTUnwrap(entryText(app) { $0.hasPrefix("Response") })
            XCTAssertGreaterThanOrEqual(response.accessibilityFrame.minY, done.accessibilityFrame.maxY,
                                        "The top card must not overlap the toolbar")
            let reader = try XCTUnwrap(MountedFixture.views(UIScrollView.self, in: app.top).last {
                MountedFixture.identifier($0) == "history-entry-scroll"
            }, "One sheet-level reader owns scrolling")
            XCTAssertEqual(MountedFixture.views(UIScrollView.self, in: reader).count, 1, "No nested scroll view")
            XCTAssertEqual(MountedFixture.views(UITextView.self, in: reader).count, 0, "No independently scrolling UITextView")
            XCTAssertNotNil(app.element("history-entry-actions"), "Actions remain in the sheet")
            let initialY = response.accessibilityFrame.minY
            try await scrolled(app, "history-entry-scroll")
            try await app.until("the top card flows with the content") { response.accessibilityFrame.minY < initialY }
        }
    }

    private func entryText(_ app: MountedFixture, _ matches: (String) -> Bool) -> NSObject? {
        MountedFixture.elements(in: app.top).last {
            $0.isAccessibilityElement && !$0.accessibilityTraits.contains(.button) && matches($0.accessibilityLabel ?? "")
        }
    }
}
