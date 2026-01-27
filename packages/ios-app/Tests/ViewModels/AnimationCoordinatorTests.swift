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

    func test_initialState_isDormant() {
        XCTAssertEqual(coordinator.currentPhase, .dormant)
        XCTAssertFalse(coordinator.supportsReasoning)
    }

    func test_initialState_noPillsVisible() {
        XCTAssertFalse(coordinator.showContextPill)
        XCTAssertFalse(coordinator.showModelPill)
        XCTAssertFalse(coordinator.showReasoningPill)
    }

    func test_initialState_noToolsVisible() {
        XCTAssertTrue(coordinator.visibleToolCallIds.isEmpty)
    }

    // MARK: - Pill State Tests

    func test_resetPillState_setsToDormant() {
        // Given - some pills visible
        coordinator.setPillsVisibleImmediately(supportsReasoning: true)

        // When
        coordinator.resetPillState()

        // Then
        XCTAssertEqual(coordinator.currentPhase, .dormant)
        XCTAssertFalse(coordinator.supportsReasoning)
    }

    func test_setPillsVisibleImmediately_withoutReasoning() {
        // When
        coordinator.setPillsVisibleImmediately(supportsReasoning: false)

        // Then
        XCTAssertEqual(coordinator.currentPhase, .modelPillVisible)
        XCTAssertTrue(coordinator.showContextPill)
        XCTAssertTrue(coordinator.showModelPill)
        XCTAssertFalse(coordinator.showReasoningPill)
    }

    func test_setPillsVisibleImmediately_withReasoning() {
        // When
        coordinator.setPillsVisibleImmediately(supportsReasoning: true)

        // Then
        XCTAssertEqual(coordinator.currentPhase, .reasoningPillVisible)
        XCTAssertTrue(coordinator.showContextPill)
        XCTAssertTrue(coordinator.showModelPill)
        XCTAssertTrue(coordinator.showReasoningPill)
    }

    // MARK: - Pill Phase Comparisons

    func test_pillMorphPhase_ordering() {
        XCTAssertTrue(AnimationCoordinator.PillMorphPhase.dormant < .contextPillVisible)
        XCTAssertTrue(AnimationCoordinator.PillMorphPhase.contextPillVisible < .modelPillVisible)
        XCTAssertTrue(AnimationCoordinator.PillMorphPhase.modelPillVisible < .reasoningPillVisible)
    }

    // MARK: - Tool Call Staggering Tests

    func test_queueToolStart_makesToolVisible() {
        // When
        coordinator.queueToolStart(toolCallId: "tool-1")

        // Then
        XCTAssertTrue(coordinator.isToolVisible("tool-1"))
    }

    func test_queueToolStart_queuesMultipleTools() {
        // When
        coordinator.queueToolStart(toolCallId: "tool-1")
        coordinator.queueToolStart(toolCallId: "tool-2")
        coordinator.queueToolStart(toolCallId: "tool-3")

        // Then
        XCTAssertTrue(coordinator.isToolVisible("tool-1"))
        XCTAssertTrue(coordinator.isToolVisible("tool-2"))
        XCTAssertTrue(coordinator.isToolVisible("tool-3"))
    }

    func test_markToolComplete_makesToolVisible() {
        // When
        coordinator.markToolComplete(toolCallId: "tool-1")

        // Then
        XCTAssertTrue(coordinator.isToolVisible("tool-1"))
    }

    func test_makeToolVisible_directlyAddsToolId() {
        // When
        coordinator.makeToolVisible("tool-direct")

        // Then
        XCTAssertTrue(coordinator.isToolVisible("tool-direct"))
    }

    func test_resetToolState_clearsPendingButKeepsVisible() {
        // Given - some tools visible
        coordinator.queueToolStart(toolCallId: "tool-1")
        coordinator.queueToolStart(toolCallId: "tool-2")

        // When
        coordinator.resetToolState()

        // Then - visible tools preserved
        XCTAssertTrue(coordinator.isToolVisible("tool-1"))
        XCTAssertTrue(coordinator.isToolVisible("tool-2"))
    }

    func test_fullReset_clearsAllToolState() {
        // Given
        coordinator.queueToolStart(toolCallId: "tool-1")
        coordinator.queueToolStart(toolCallId: "tool-2")

        // When
        coordinator.fullReset()

        // Then
        XCTAssertFalse(coordinator.isToolVisible("tool-1"))
        XCTAssertFalse(coordinator.isToolVisible("tool-2"))
        XCTAssertTrue(coordinator.visibleToolCallIds.isEmpty)
    }

    func test_isToolVisible_returnsFalseForUnknownTool() {
        XCTAssertFalse(coordinator.isToolVisible("unknown-tool"))
    }

    // MARK: - Message Cascade Tests

    func test_cascadeProgress_startsAtZero() {
        XCTAssertEqual(coordinator.cascadeProgress, 0)
        XCTAssertEqual(coordinator.totalCascadeMessages, 0)
    }

    func test_isCascadeVisible_returnsFalseWhenNotStarted() {
        XCTAssertFalse(coordinator.isCascadeVisible(index: 0))
        XCTAssertFalse(coordinator.isCascadeVisible(index: 5))
    }

    func test_cancelCascade_stopsAnimation() {
        // Given
        coordinator.startMessageCascade(totalMessages: 10) { _ in }

        // When
        coordinator.cancelCascade()

        // Then - should not crash and cascade should stop
        XCTAssertLessThanOrEqual(coordinator.cascadeProgress, 10)
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
        // Pill delays
        XCTAssertEqual(AnimationCoordinator.Timing.contextPillDelay, 0)
        XCTAssertGreaterThan(AnimationCoordinator.Timing.modelPillDelay, 0)
        XCTAssertGreaterThan(AnimationCoordinator.Timing.reasoningPillDelay, 0)

        // Cascade
        XCTAssertGreaterThan(AnimationCoordinator.Timing.cascadeMaxMessages, 0)
        XCTAssertGreaterThan(AnimationCoordinator.Timing.cascadeSpringResponse, 0)

        // Tool stagger
        XCTAssertGreaterThan(AnimationCoordinator.Timing.toolStaggerInterval, 0)
        XCTAssertGreaterThan(AnimationCoordinator.Timing.toolStaggerCap, 0)
    }

    // MARK: - Reasoning Support Updates

    func test_updateReasoningSupport_toFalse_hidesReasoningPill() {
        // Given
        coordinator.setPillsVisibleImmediately(supportsReasoning: true)
        XCTAssertTrue(coordinator.showReasoningPill)

        // When
        coordinator.updateReasoningSupport(false)

        // Then
        XCTAssertFalse(coordinator.supportsReasoning)
        XCTAssertFalse(coordinator.showReasoningPill)
    }
}
