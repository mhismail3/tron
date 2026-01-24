import XCTest
@testable import TronMobile

/// Tests for ScrollStateCoordinator scroll functionality
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

    func testScrollToTargetSetsReviewingMode() {
        // Given: Coordinator in following mode
        XCTAssertEqual(coordinator.mode, .following)

        // When: Scrolling to target
        coordinator.scrollToTarget(messageId: UUID(), using: nil)

        // Then: Mode should be reviewing (user initiated navigation)
        XCTAssertEqual(coordinator.mode, .reviewing)
    }

    func testScrollToTargetClearsUnreadContent() {
        // Given: Coordinator has unread content
        // First put it in reviewing mode with unread content
        coordinator.userDidScroll(isNearBottom: false)
        XCTAssertEqual(coordinator.mode, .reviewing)
        coordinator.contentAdded()
        XCTAssertTrue(coordinator.hasUnreadContent)

        // When: Scrolling to target
        coordinator.scrollToTarget(messageId: UUID(), using: nil)

        // Then: Unread content should be cleared
        XCTAssertFalse(coordinator.hasUnreadContent)
    }

    func testScrollToTargetSetsGracePeriod() {
        // When: Scrolling to target
        coordinator.scrollToTarget(messageId: UUID(), using: nil)

        // Then: Grace period should prevent immediate mode switches
        // User scroll detection should be suppressed during grace period
        coordinator.userDidScroll(isNearBottom: true)

        // Mode should still be reviewing because we're in grace period
        XCTAssertEqual(coordinator.mode, .reviewing)
    }

    // MARK: - Integration with Existing State

    func testUserSentMessageResetsToFollowing() {
        // Given: Coordinator in reviewing mode
        coordinator.scrollToTarget(messageId: UUID(), using: nil)
        XCTAssertEqual(coordinator.mode, .reviewing)

        // When: User sends a message
        coordinator.userSentMessage()

        // Then: Mode should reset to following
        XCTAssertEqual(coordinator.mode, .following)
    }

    func testUserTappedScrollToBottomResetsToFollowing() {
        // Given: Coordinator in reviewing mode
        coordinator.scrollToTarget(messageId: UUID(), using: nil)
        XCTAssertEqual(coordinator.mode, .reviewing)

        // When: User taps scroll to bottom
        coordinator.userTappedScrollToBottom()

        // Then: Mode should reset to following
        XCTAssertEqual(coordinator.mode, .following)
    }

    func testUserDidScrollSwitchesToReviewing() {
        // Given: Coordinator in following mode
        XCTAssertEqual(coordinator.mode, .following)

        // When: User scrolls away from bottom
        coordinator.userDidScroll(isNearBottom: false)

        // Then: Mode should switch to reviewing
        XCTAssertEqual(coordinator.mode, .reviewing)
    }

    func testUserDidScrollNearBottomStaysFollowing() {
        // Given: Coordinator in following mode
        XCTAssertEqual(coordinator.mode, .following)

        // When: User scrolls but stays near bottom
        coordinator.userDidScroll(isNearBottom: true)

        // Then: Mode should stay following
        XCTAssertEqual(coordinator.mode, .following)
    }

    func testUserDidScrollNearBottomSwitchesBackToFollowing() {
        // Given: Coordinator in reviewing mode
        coordinator.userDidScroll(isNearBottom: false)
        XCTAssertEqual(coordinator.mode, .reviewing)

        // When: User scrolls back to near bottom
        coordinator.userDidScroll(isNearBottom: true)

        // Then: Mode should switch back to following
        XCTAssertEqual(coordinator.mode, .following)
    }

    // MARK: - Content Changes

    func testContentAddedSetsUnreadWhenReviewing() {
        // Given: Coordinator in reviewing mode
        coordinator.userDidScroll(isNearBottom: false)
        XCTAssertEqual(coordinator.mode, .reviewing)
        XCTAssertFalse(coordinator.hasUnreadContent)

        // When: New content is added
        coordinator.contentAdded()

        // Then: Should have unread content
        XCTAssertTrue(coordinator.hasUnreadContent)
    }

    func testContentAddedDoesNotSetUnreadWhenFollowing() {
        // Given: Coordinator in following mode
        XCTAssertEqual(coordinator.mode, .following)

        // When: New content is added
        coordinator.contentAdded()

        // Then: Should not have unread content
        XCTAssertFalse(coordinator.hasUnreadContent)
    }

    func testProcessingEndedClearsUnreadContent() {
        // Given: Coordinator with unread content
        coordinator.userDidScroll(isNearBottom: false)
        coordinator.contentAdded()
        XCTAssertTrue(coordinator.hasUnreadContent)

        // When: Processing ends
        coordinator.processingEnded()

        // Then: Unread content should be cleared
        XCTAssertFalse(coordinator.hasUnreadContent)
    }

    // MARK: - Should Show Scroll To Bottom Button

    func testShouldNotShowButtonAfterTargetScrollWithNoUnread() {
        // Given: Navigation completed, no new content
        coordinator.scrollToTarget(messageId: UUID(), using: nil)

        // Then: Should not show scroll to bottom button
        XCTAssertFalse(coordinator.shouldShowScrollToBottomButton)
    }

    func testShouldShowButtonAfterTargetScrollWithNewContent() {
        // Given: Navigation completed
        coordinator.scrollToTarget(messageId: UUID(), using: nil)
        XCTAssertEqual(coordinator.mode, .reviewing)

        // When: New content arrives while in reviewing mode
        coordinator.contentAdded()

        // Then: Should show scroll to bottom button (mode is reviewing + unread content)
        XCTAssertTrue(coordinator.shouldShowScrollToBottomButton)
    }

    func testShouldAutoScrollWhenFollowing() {
        // Given: Coordinator in following mode
        XCTAssertEqual(coordinator.mode, .following)

        // Then: Should auto scroll
        XCTAssertTrue(coordinator.shouldAutoScroll)
    }

    func testShouldNotAutoScrollWhenReviewing() {
        // Given: Coordinator in reviewing mode
        coordinator.userDidScroll(isNearBottom: false)
        XCTAssertEqual(coordinator.mode, .reviewing)

        // Then: Should not auto scroll
        XCTAssertFalse(coordinator.shouldAutoScroll)
    }
}
