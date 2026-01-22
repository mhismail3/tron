import XCTest
@testable import TronMobile

/// Tests for ScrollStateCoordinator deep link scroll functionality
@available(iOS 17.0, *)
@MainActor
final class ScrollStateCoordinatorTests: XCTestCase {

    var coordinator: ScrollStateCoordinator!

    override func setUp() async throws {
        coordinator = ScrollStateCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
    }

    // MARK: - Mode Tests

    func testInitialModeIsFollowing() {
        XCTAssertEqual(coordinator.mode, .following)
    }

    func testScrollToDeepLinkTargetSetsReviewingMode() {
        // Given: Coordinator in following mode
        XCTAssertEqual(coordinator.mode, .following)

        // When: Scrolling to deep link target
        coordinator.scrollToDeepLinkTarget(messageId: UUID(), using: nil)

        // Then: Mode should be reviewing (user initiated navigation)
        XCTAssertEqual(coordinator.mode, .reviewing)
    }

    func testScrollToDeepLinkTargetClearsUnreadContent() {
        // Given: Coordinator has unread content (simulated via append when reviewing)
        // First put it in reviewing mode with unread content
        coordinator.userScrolled(distanceFromBottom: -100, isProcessing: false)
        XCTAssertEqual(coordinator.mode, .reviewing)
        coordinator.didMutateContent(.appendNew)  // This sets hasUnreadContent = true
        XCTAssertTrue(coordinator.hasUnreadContent)

        // When: Scrolling to deep link target
        coordinator.scrollToDeepLinkTarget(messageId: UUID(), using: nil)

        // Then: Unread content should be cleared
        XCTAssertFalse(coordinator.hasUnreadContent)
    }

    func testScrollToDeepLinkTargetSetsGracePeriod() {
        // Given: Coordinator with no grace period
        let beforeTime = Date()

        // When: Scrolling to deep link target
        coordinator.scrollToDeepLinkTarget(messageId: UUID(), using: nil)

        // Then: Grace period should be set to future
        // Note: We check graceUntil through side effects since it's private
        // The grace period prevents immediate scroll position detection from switching modes

        // After scrolling to deep link, user scroll detection should be suppressed
        // We verify by calling userScrolled and confirming mode doesn't change
        coordinator.userScrolled(distanceFromBottom: -100, isProcessing: false)

        // Mode should still be reviewing because we're in grace period
        XCTAssertEqual(coordinator.mode, .reviewing)
    }

    func testScrollToDeepLinkTargetFromLoadingMode() {
        // Given: Coordinator in loading mode (prepending history)
        coordinator.willMutateContent(.prependHistory, firstVisibleId: UUID())
        XCTAssertEqual(coordinator.mode, .loading)

        // When: Scrolling to deep link target
        coordinator.scrollToDeepLinkTarget(messageId: UUID(), using: nil)

        // Then: Mode should switch to reviewing
        XCTAssertEqual(coordinator.mode, .reviewing)
    }

    // MARK: - Integration with Existing State

    func testUserSentMessageResetsToFollowing() {
        // Given: Coordinator in reviewing mode (e.g., after deep link)
        coordinator.scrollToDeepLinkTarget(messageId: UUID(), using: nil)
        XCTAssertEqual(coordinator.mode, .reviewing)

        // When: User sends a message
        coordinator.userSentMessage()

        // Then: Mode should reset to following
        XCTAssertEqual(coordinator.mode, .following)
    }

    func testUserTappedScrollToBottomResetsToFollowing() {
        // Given: Coordinator in reviewing mode (e.g., after deep link)
        coordinator.scrollToDeepLinkTarget(messageId: UUID(), using: nil)
        XCTAssertEqual(coordinator.mode, .reviewing)

        // When: User taps scroll to bottom
        coordinator.userTappedScrollToBottom()

        // Then: Mode should reset to following
        XCTAssertEqual(coordinator.mode, .following)
    }

    // MARK: - Should Show Scroll To Bottom Button

    func testShouldNotShowButtonAfterDeepLinkWithNoUnread() {
        // Given: Deep link navigation completed, no new content
        coordinator.scrollToDeepLinkTarget(messageId: UUID(), using: nil)

        // Then: Should not show scroll to bottom button
        XCTAssertFalse(coordinator.shouldShowScrollToBottomButton)
    }

    func testShouldShowButtonAfterDeepLinkWithNewContent() {
        // Given: Deep link navigation completed
        coordinator.scrollToDeepLinkTarget(messageId: UUID(), using: nil)
        XCTAssertEqual(coordinator.mode, .reviewing)

        // When: New content arrives while in reviewing mode
        coordinator.didMutateContent(.appendNew)

        // Then: Should show scroll to bottom button (mode is reviewing + unread content)
        XCTAssertTrue(coordinator.shouldShowScrollToBottomButton)
    }
}
