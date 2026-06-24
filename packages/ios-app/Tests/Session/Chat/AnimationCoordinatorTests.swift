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

    func test_initialState_noCapabilitiesVisible() {
        XCTAssertTrue(coordinator.visibleInvocationIds.isEmpty)
    }

    // MARK: - Capability Call Staggering Tests

    func test_queueCapabilityInvocationStart_makesCapabilityVisible() {
        // When
        coordinator.queueCapabilityInvocationStart(invocationId: "capability-1")

        // Then
        XCTAssertTrue(coordinator.isCapabilityInvocationVisible("capability-1"))
    }

    func test_queueCapabilityInvocationStart_queuesMultipleCapabilities() {
        // When
        coordinator.queueCapabilityInvocationStart(invocationId: "capability-1")
        coordinator.queueCapabilityInvocationStart(invocationId: "capability-2")
        coordinator.queueCapabilityInvocationStart(invocationId: "capability-3")

        // Then
        XCTAssertTrue(coordinator.isCapabilityInvocationVisible("capability-1"))
        XCTAssertTrue(coordinator.isCapabilityInvocationVisible("capability-2"))
        XCTAssertTrue(coordinator.isCapabilityInvocationVisible("capability-3"))
    }

    func test_markCapabilityInvocationComplete_makesCapabilityVisible() {
        // When
        coordinator.markCapabilityInvocationComplete(invocationId: "capability-1")

        // Then
        XCTAssertTrue(coordinator.isCapabilityInvocationVisible("capability-1"))
    }

    func test_makeCapabilityInvocationVisible_directlyAddsCapabilityId() {
        // When
        coordinator.makeCapabilityInvocationVisible("capability-direct")

        // Then
        XCTAssertTrue(coordinator.isCapabilityInvocationVisible("capability-direct"))
    }

    func test_resetCapabilityState_clearsPendingButKeepsVisible() {
        // Given - some capabilities visible
        coordinator.queueCapabilityInvocationStart(invocationId: "capability-1")
        coordinator.queueCapabilityInvocationStart(invocationId: "capability-2")

        // When
        coordinator.resetCapabilityState()

        // Then - visible capabilities preserved
        XCTAssertTrue(coordinator.isCapabilityInvocationVisible("capability-1"))
        XCTAssertTrue(coordinator.isCapabilityInvocationVisible("capability-2"))
    }

    func test_fullReset_clearsAllCapabilityState() {
        // Given
        coordinator.queueCapabilityInvocationStart(invocationId: "capability-1")
        coordinator.queueCapabilityInvocationStart(invocationId: "capability-2")

        // When
        coordinator.fullReset()

        // Then
        XCTAssertFalse(coordinator.isCapabilityInvocationVisible("capability-1"))
        XCTAssertFalse(coordinator.isCapabilityInvocationVisible("capability-2"))
        XCTAssertTrue(coordinator.visibleInvocationIds.isEmpty)
    }

    func test_isCapabilityInvocationVisible_returnsFalseForUnknownCapability() {
        XCTAssertFalse(coordinator.isCapabilityInvocationVisible("unknown-capability"))
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
        _ = AnimationCoordinator.capabilityAnimation
        _ = AnimationCoordinator.cascadeAnimation
    }

    // MARK: - Timing Constants

    func test_timingConstants_areReasonable() {
        // Cascade
        XCTAssertGreaterThan(AnimationCoordinator.Timing.cascadeMaxMessages, 0)
        XCTAssertGreaterThan(AnimationCoordinator.Timing.cascadeSpringResponse, 0)

        // Capability stagger
        XCTAssertGreaterThan(AnimationCoordinator.Timing.capabilityStaggerInterval, 0)
        XCTAssertGreaterThan(AnimationCoordinator.Timing.capabilityStaggerCap, 0)
    }
}
