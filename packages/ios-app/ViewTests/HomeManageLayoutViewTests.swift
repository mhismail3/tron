import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeManageLayoutViewTests: ShuffledTestCase {
    func testRingAlignmentReviewLight() async throws { try await ringAlignment([]) }
    func testRingAlignmentReviewDark() async throws { try await ringAlignment(["-home-dark"]) }
    func testRingAlignmentReviewXXXL() async throws { try await ringAlignment([], contentSize: .extraExtraExtraLarge) }

    private func ringAlignment(_ arguments: [String], contentSize: UIContentSizeCategory = .large) async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"] + arguments, contentSize: contentSize) { app in
            try await openManageHome(app)
            @MainActor func title() -> NSObject? {
                MountedFixture.elements(in: app.top).last { $0.accessibilityLabel == "969K tokens left" && !$0.accessibilityTraits.contains(.button) }
            }
            try await app.until("the context summary") {
                app.element("home-context-ring") != nil && app.element("home-context-detail") != nil && title() != nil
            }
            let ring = app.element("home-context-ring")!.accessibilityFrame
            let combined = title()!.accessibilityFrame.union(app.element("home-context-detail")!.accessibilityFrame)
            XCTAssertEqual(ring.midY, combined.midY, accuracy: 1.5, "The ring centers on title and subtext together, not only the title")
        }
    }
}
