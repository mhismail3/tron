import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class AnnotationOnlySteerViewTests: ShuffledTestCase {
    func testAnnotationOnlySteerBelongsToCardAndRemainsEditable() async throws {
        for mode in ["light", "dark"] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-foreground-queued-editor",
                               "-foreground-queued-steer", "-foreground-queued-annotation"]
                              + (mode == "dark" ? ["-home-dark"] : []), theme: .burgundy) { app in
                try await app.activate("home-pinned-row")
                @MainActor func annotation() -> NSObject? {
                    MountedFixture.elements(in: app.top).first {
                        $0.accessibilityLabel?.hasPrefix("Show annotation") == true && $0.accessibilityTraits.contains(.button)
                    }
                }
                @MainActor func arrow() -> NSObject? {
                    MountedFixture.elements(in: app.top).first { MountedFixture.identifier($0) == "arrow.turn.up.right" }
                }
                try await app.until("the queued card") { annotation() != nil && arrow() != nil }
                XCTAssertGreaterThan(annotation()!.accessibilityFrame.minY, arrow()!.accessibilityFrame.maxY,
                                     "The annotation must be content beneath the queue header, inside its card, not detached above it")
                XCTAssertTrue(annotation()!.accessibilityActivate())
                try await app.until("the annotation sheet") { app.element("chat.annotation.comment") != nil }
                try await app.activate("Done")
                try await app.until("the card returns") { app.element("chat.annotation.comment") == nil && arrow() != nil }
                @MainActor func card() -> NSObject? {
                    MountedFixture.elements(in: app.top).first {
                        $0.accessibilityHint == "Opens the queued message editor" && $0.accessibilityTraits.contains(.button)
                    }
                }
                try await app.until("the card is activatable") { card() != nil }
                XCTAssertTrue(card()!.accessibilityActivate())
                @MainActor func editor() -> NSObject? {
                    MountedFixture.elements(in: app.top).first {
                        $0.isAccessibilityElement && $0.accessibilityLabel == "Queued message" && !$0.accessibilityTraits.contains(.header)
                    }
                }
                try await app.until("the queued editor") {
                    editor() != nil && app.element("Save queued message") != nil && app.element("Remove queued message") != nil
                }
                XCTAssertTrue((editor()!.accessibilityValue ?? "").hasSuffix("</annotation>"), "The editor retains the annotation-only envelope")
                XCTAssertFalse(app.element("Save queued message")!.accessibilityTraits.contains(.notEnabled))
                XCTAssertFalse(app.element("Remove queued message")!.accessibilityTraits.contains(.notEnabled))
            }
        }
    }
}
