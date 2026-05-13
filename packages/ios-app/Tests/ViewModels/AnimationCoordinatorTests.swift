import XCTest
@testable import TronMobile

// MARK: - AnimationCoordinator Tests

@MainActor
final class AnimationCoordinatorTests: XCTestCase {

    var coordinator: AnimationCoordinator!

    override func setUp() async throws {
        coordinator = AnimationCoordinator()
    }

    override func tearDown() async throws {
        coordinator.fullReset()
        coordinator = nil
    }

    // MARK: - Initial State Tests

    func test_initialState_noToolsVisible() {
        XCTAssertTrue(coordinator.visibleInvocationIds.isEmpty)
    }

    // MARK: - Tool Call Staggering Tests

    func test_queueCapabilityInvocationStart_makesToolVisible() {
        // When
        coordinator.queueCapabilityInvocationStart(invocationId: "tool-1")

        // Then
        XCTAssertTrue(coordinator.isToolVisible("tool-1"))
    }

    func test_queueCapabilityInvocationStart_queuesMultipleTools() {
        // When
        coordinator.queueCapabilityInvocationStart(invocationId: "tool-1")
        coordinator.queueCapabilityInvocationStart(invocationId: "tool-2")
        coordinator.queueCapabilityInvocationStart(invocationId: "tool-3")

        // Then
        XCTAssertTrue(coordinator.isToolVisible("tool-1"))
        XCTAssertTrue(coordinator.isToolVisible("tool-2"))
        XCTAssertTrue(coordinator.isToolVisible("tool-3"))
    }

    func test_markCapabilityInvocationComplete_makesToolVisible() {
        // When
        coordinator.markCapabilityInvocationComplete(invocationId: "tool-1")

        // Then
        XCTAssertTrue(coordinator.isToolVisible("tool-1"))
    }

    func test_makeCapabilityInvocationVisible_directlyAddsToolId() {
        // When
        coordinator.makeCapabilityInvocationVisible("tool-direct")

        // Then
        XCTAssertTrue(coordinator.isToolVisible("tool-direct"))
    }

    func test_resetToolState_clearsPendingButKeepsVisible() {
        // Given - some tools visible
        coordinator.queueCapabilityInvocationStart(invocationId: "tool-1")
        coordinator.queueCapabilityInvocationStart(invocationId: "tool-2")

        // When
        coordinator.resetToolState()

        // Then - visible tools preserved
        XCTAssertTrue(coordinator.isToolVisible("tool-1"))
        XCTAssertTrue(coordinator.isToolVisible("tool-2"))
    }

    func test_fullReset_clearsAllToolState() {
        // Given
        coordinator.queueCapabilityInvocationStart(invocationId: "tool-1")
        coordinator.queueCapabilityInvocationStart(invocationId: "tool-2")

        // When
        coordinator.fullReset()

        // Then
        XCTAssertFalse(coordinator.isToolVisible("tool-1"))
        XCTAssertFalse(coordinator.isToolVisible("tool-2"))
        XCTAssertTrue(coordinator.visibleInvocationIds.isEmpty)
    }

    func test_isToolVisible_returnsFalseForUnknownTool() {
        XCTAssertFalse(coordinator.isToolVisible("unknown-tool"))
    }

    // MARK: - Message Cascade Tests

    func test_cascadeProgress_startsAtZero() {
        XCTAssertEqual(coordinator.cascadeProgress, 0)
        XCTAssertEqual(coordinator.totalCascadeMessages, 0)
    }

    func test_isCascadeVisibleFromBottom_returnsFalseWhenNotStarted() {
        // With 10 total messages and 0 progress, no messages should be visible
        XCTAssertFalse(coordinator.isCascadeVisibleFromBottom(index: 0, total: 10))
        XCTAssertFalse(coordinator.isCascadeVisibleFromBottom(index: 5, total: 10))
        XCTAssertFalse(coordinator.isCascadeVisibleFromBottom(index: 9, total: 10))
    }

    func test_cancelCascade_stopsAnimation() {
        // Given - start a bottom-up cascade
        coordinator.startBottomUpCascade(totalMessages: 10)

        // When
        coordinator.cancelCascade()

        // Then - should not crash and cascade should stop
        XCTAssertLessThanOrEqual(coordinator.cascadeProgress, 10)
        XCTAssertFalse(coordinator.isCascading)
    }

    func test_isCascading_returnsTrueWhenCascadeRunning() {
        // Given/When
        coordinator.startBottomUpCascade(totalMessages: 10)

        // Then
        XCTAssertTrue(coordinator.isCascading)

        // Cleanup
        coordinator.cancelCascade()
    }

    func test_makeAllMessagesVisible_setsProgressToCount() {
        // When
        coordinator.makeAllMessagesVisible(count: 25)

        // Then
        XCTAssertEqual(coordinator.cascadeProgress, 25)
        XCTAssertEqual(coordinator.totalCascadeMessages, 25)
        XCTAssertFalse(coordinator.isCascading)
    }

    func test_isCascadeVisibleFromBottom_logic() {
        // Given - simulate cascade progress of 3 out of 10 messages
        coordinator.makeAllMessagesVisible(count: 0)  // Reset
        // Manually set progress to test visibility logic
        // With total=10 and progress=3, messages 7,8,9 should be visible (bottom-up)

        // We can't easily set cascadeProgress directly, so test via makeAllMessagesVisible
        coordinator.makeAllMessagesVisible(count: 10)

        // Then - all messages should be visible when progress equals total
        XCTAssertTrue(coordinator.isCascadeVisibleFromBottom(index: 0, total: 10))
        XCTAssertTrue(coordinator.isCascadeVisibleFromBottom(index: 9, total: 10))
    }

    // MARK: - Animation Helpers

    func test_staticAnimations_exist() {
        // Verify animation helpers return valid animations
        _ = AnimationCoordinator.pillAnimation
        _ = AnimationCoordinator.toolAnimation
        _ = AnimationCoordinator.cascadeAnimation
    }

    // MARK: - Timing Constants

    func test_timingConstants_areReasonable() {
        // Cascade
        XCTAssertGreaterThan(AnimationCoordinator.Timing.cascadeMaxMessages, 0)
        XCTAssertGreaterThan(AnimationCoordinator.Timing.cascadeSpringResponse, 0)

        // Tool stagger
        XCTAssertGreaterThan(AnimationCoordinator.Timing.toolStaggerInterval, 0)
        XCTAssertGreaterThan(AnimationCoordinator.Timing.toolStaggerCap, 0)
    }
}
