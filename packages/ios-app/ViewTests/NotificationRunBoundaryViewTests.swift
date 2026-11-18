import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class NotificationRunBoundaryViewTests: ShuffledTestCase {
    func testInterleavedNotificationsPreserveConversationAndToolBoundaries() async throws {
        try await mounted(["-tron-subagent-parity-fixture", "-presentation-polish", "-interleaved-events", "-dark"]) { app in
            @MainActor func errors() -> [NSObject] {
                MountedFixture.elements(in: app.top).filter {
                    $0.accessibilityLabel == "Tron · Notification, Error" && $0.accessibilityTraits.contains(.button)
                }
            }
            try await app.until("the error notifications") { !errors().isEmpty }
            XCTAssertEqual(errors().count, 2, app.tree())
            XCTAssertTrue(MountedFixture.elements(in: app.top).contains {
                MountedFixture.identifier($0) == "chat.assistant.selectable-text"
                    && (($0 as? UITextView)?.text == "Conversation between independent events."
                        || $0.accessibilityValue == "Conversation between independent events.")
            }, app.tree())
            XCTAssertTrue(MountedFixture.elements(in: app.top).contains {
                $0.accessibilityLabel == "Read file, Interrupted" && $0.accessibilityTraits.contains(.button)
            }, app.tree())
            let mids = try await app.still("the error notifications") {
                let frames = errors().map(\.accessibilityFrame).sorted { $0.minY < $1.minY }
                return frames.count == 2 ? frames.map(\.midY) : nil
            }
            XCTAssertGreaterThan(mids[1] - mids[0], 80, "Prose and tools must remain chronological boundaries, not join an event run")
        }
    }
}
