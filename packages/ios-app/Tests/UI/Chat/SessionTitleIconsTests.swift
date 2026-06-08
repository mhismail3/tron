import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class SessionTitleIconsTests: XCTestCase {

    // Guard: canonical fork tint is coral. Prevents regressions that silently
    // reintroduce purple.
    func test_forkColor_isCoral() {
        XCTAssertEqual(SessionTitleIcons.forkColor, Color.tronCoral)
    }

    func test_icons_none_whenNotForked() {
        let icons = SessionTitleIcons.iconsShown(isFork: false)
        XCTAssertEqual(icons, [])
    }

    func test_icons_forkOnly() {
        let icons = SessionTitleIcons.iconsShown(isFork: true)
        XCTAssertEqual(icons, [.fork])
    }

    func test_accessibilityDescriptors_emptyWhenNotForked() {
        XCTAssertEqual(
            SessionTitleIcons.accessibilityDescriptors(isFork: false),
            []
        )
    }

    func test_accessibilityDescriptors_forked() {
        XCTAssertEqual(
            SessionTitleIcons.accessibilityDescriptors(isFork: true),
            ["forked"]
        )
    }
}
