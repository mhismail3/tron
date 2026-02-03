import Testing
import Foundation
@testable import TronMobile

/// Tests for ScrollGeometryHandler decision logic
/// Validates content growth detection vs user scroll detection to prevent
/// incorrect "New Content" button appearance
@Suite("Scroll Geometry Handler Tests")
@MainActor
struct ScrollGeometryHandlerTests {

    // MARK: - Test Scenario 1: Content grew, following mode, not near bottom → noChange

    @Test("Content grew while following - should not switch to reviewing")
    func testContentGrewWhileFollowing() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 100, contentHeight: 1100)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        #expect(decision == .noChange)
    }

    // MARK: - Test Scenario 2: Content grew, reviewing mode, not near bottom → noChange

    @Test("Content grew while reviewing - should stay in reviewing (no extra action)")
    func testContentGrewWhileReviewing() {
        let oldState = ScrollState(isNearBottom: false, offset: 50, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 50, contentHeight: 1100)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: false,
            isCascading: false
        )

        // In reviewing mode, content growth doesn't need to trigger mode change
        // The existing mode is already correct
        #expect(decision == .updateNearBottom(false))
    }

    // MARK: - Test Scenario 3: User scrolled up (offset decreased >5) → scrolledUp

    @Test("User scrolled up - should switch to reviewing")
    func testUserScrolledUp() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 90, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        #expect(decision == .scrolledUp)
    }

    // MARK: - Test Scenario 4: User scrolled down to bottom → updateNearBottom(true)

    @Test("User scrolled down to bottom - should update near bottom status")
    func testUserScrolledDownToBottom() {
        let oldState = ScrollState(isNearBottom: false, offset: 50, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: true, offset: 150, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: false,
            isCascading: false
        )

        #expect(decision == .updateNearBottom(true))
    }

    // MARK: - Test Scenario 5: During cascade animation → noChange

    @Test("During cascade animation - should not process changes")
    func testDuringCascadeAnimation() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 50, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: true
        )

        #expect(decision == .noChange)
    }

    // MARK: - Test Scenario 6: No significant change in state → updateNearBottom

    @Test("No significant change - should report current near bottom status")
    func testNoSignificantChange() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: true, offset: 101, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        #expect(decision == .updateNearBottom(true))
    }

    // MARK: - Test Scenario 7: Content shrank, now near bottom → updateNearBottom(true)

    @Test("Content shrank - should update near bottom status")
    func testContentShrankNowNearBottom() {
        let oldState = ScrollState(isNearBottom: false, offset: 100, contentHeight: 1500)
        let newState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: false,
            isCascading: false
        )

        #expect(decision == .updateNearBottom(true))
    }

    // MARK: - Test Scenario 8: Small offset noise (<5 points) → normal update

    @Test("Small offset noise - should not trigger scrolled up")
    func testSmallOffsetNoise() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: true, offset: 97, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        // Small changes shouldn't trigger scrolledUp
        #expect(decision == .updateNearBottom(true))
    }

    // MARK: - Test Scenario 9: Large content growth in following mode → noChange

    @Test("Large content growth while following - should not switch to reviewing")
    func testLargeContentGrowthWhileFollowing() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 100, contentHeight: 1200)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        #expect(decision == .noChange)
    }

    // MARK: - Test Scenario 10: Following mode, at bottom, no change → updateNearBottom(true)

    @Test("Following mode at bottom stable - should confirm near bottom")
    func testFollowingModeAtBottomStable() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        #expect(decision == .updateNearBottom(true))
    }

    // MARK: - Edge Cases

    @Test("User scrolls up significantly - should always detect")
    func testUserScrollsUpSignificantly() {
        let oldState = ScrollState(isNearBottom: true, offset: 500, contentHeight: 2000)
        let newState = ScrollState(isNearBottom: false, offset: 100, contentHeight: 2000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        #expect(decision == .scrolledUp)
    }

    @Test("Content grew significantly with offset increase")
    func testContentGrewWithOffsetIncrease() {
        // Simulates auto-scroll catching up: content grew and offset increased
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: true, offset: 200, contentHeight: 1100)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        #expect(decision == .updateNearBottom(true))
    }

    @Test("Threshold boundary - exactly 5 points offset decrease")
    func testThresholdBoundaryExactly5Points() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: true, offset: 95, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        // Exactly 5 points should NOT trigger scrolledUp (threshold is > 5)
        #expect(decision == .updateNearBottom(true))
    }

    @Test("Just over threshold - 6 points offset decrease")
    func testJustOverThreshold() {
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 94, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        // > 5 points should trigger scrolledUp
        #expect(decision == .scrolledUp)
    }

    // MARK: - Model Switch / Layout Change Scenarios

    @Test("Layout change without content growth - should stay in following mode")
    func testLayoutChangeWithoutContentGrowth() {
        // Simulates model switch notification where geometry change fires
        // before contentHeight is updated - isNearBottom becomes false
        // but contentHeight hasn't changed yet
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 100, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        // In following mode, any isNearBottom=false without user scroll should be noChange
        #expect(decision == .noChange)
    }

    @Test("Following mode not near bottom - should always return noChange unless scrolled up")
    func testFollowingModeNotNearBottomAlwaysNoChange() {
        // Various scenarios where following mode + not near bottom should return noChange
        let oldState = ScrollState(isNearBottom: true, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 105, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: true,
            isCascading: false
        )

        // Offset increased (scrolled down), but not near bottom yet - stay following
        #expect(decision == .noChange)
    }

    @Test("Reviewing mode not near bottom - should update status")
    func testReviewingModeNotNearBottom() {
        // In reviewing mode, we DO want to report isNearBottom status
        let oldState = ScrollState(isNearBottom: false, offset: 100, contentHeight: 1000)
        let newState = ScrollState(isNearBottom: false, offset: 100, contentHeight: 1000)

        let decision = ScrollGeometryHandler.processGeometryChange(
            oldState: oldState,
            newState: newState,
            isFollowingMode: false,
            isCascading: false
        )

        // Reviewing mode reports actual isNearBottom status
        #expect(decision == .updateNearBottom(false))
    }
}
