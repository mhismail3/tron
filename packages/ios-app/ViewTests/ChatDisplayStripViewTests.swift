import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ChatDisplayStripViewTests: ShuffledTestCase {
    func testSegmentContinuationAfterSplitDisplayGroupOpens() async throws {
        try await mounted(["-tron-chat-display-fixture", "-chat-display-segment-continuation"]) { app in
            @MainActor func summary() -> UITextView? {
                MountedFixture.views(UITextView.self, in: app.top).last {
                    MountedFixture.identifier($0) == "chat.assistant.selectable-text" && $0.text.contains("Segment continuation settled.")
                }
            }
            @MainActor func photo() -> NSObject? {
                MountedFixture.elements(in: app.top).last {
                    $0.accessibilityLabel == "Open Segment photo photo preview" && $0.accessibilityTraits.contains(.button)
                }
            }
            @MainActor func bash() -> NSObject? {
                MountedFixture.elements(in: app.top).last {
                    $0.accessibilityLabel?.hasPrefix("Run command, Completed") == true && $0.accessibilityTraits.contains(.button)
                }
            }
            try await app.until("the continuation transcript") { summary() != nil && photo() != nil && bash() != nil }
            XCTAssertFalse(MountedFixture.elements(in: app.top).contains { $0.accessibilityLabel == "Conversation unavailable" }, app.tree())
            let photoFrame = photo()!.accessibilityFrame, bashFrame = bash()!.accessibilityFrame
            XCTAssertGreaterThan(bashFrame.minY, photoFrame.maxY, "The continuation keeps its own row below the display")
        }
    }
}
