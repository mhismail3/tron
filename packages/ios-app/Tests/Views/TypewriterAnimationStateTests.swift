import XCTest
@testable import TronMobile

@MainActor
final class TypewriterAnimationStateTests: XCTestCase {

    // MARK: - Normal Animation

    func testAnimate_deletesOldThenTypesNew() async {
        let state = TypewriterAnimationState(text: "old", characterDelay: .milliseconds(1))
        state.animate(to: "new")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "new")
    }

    func testAnimate_fromEmpty_typesOnly() async {
        let state = TypewriterAnimationState(text: "", characterDelay: .milliseconds(1))
        state.animate(to: "hello")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "hello")
    }

    func testAnimate_toEmpty_deletesOnly() async {
        let state = TypewriterAnimationState(text: "hello", characterDelay: .milliseconds(1))
        state.animate(to: "")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "")
    }

    func testAnimate_toSameText_endsUnchanged() async {
        let state = TypewriterAnimationState(text: "same", characterDelay: .milliseconds(1))
        state.animate(to: "same")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "same")
    }

    func testAnimate_longText_completesCorrectly() async {
        let state = TypewriterAnimationState(text: "preparedness", characterDelay: .milliseconds(1))
        state.animate(to: "Exploring Code Structure")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "Exploring Code Structure")
    }

    // MARK: - Cancellation Recovery

    func testCancel_duringDelete_recoversToTarget() async {
        let state = TypewriterAnimationState(text: "preparedness", characterDelay: .milliseconds(50))
        state.animate(to: "New Title")
        try? await Task.sleep(for: .milliseconds(100))
        state.animate(to: "Final Title")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "Final Title")
    }

    func testCancel_duringType_recoversToTarget() async {
        let state = TypewriterAnimationState(text: "", characterDelay: .milliseconds(50))
        state.animate(to: "Long Title Here")
        try? await Task.sleep(for: .milliseconds(100))
        state.animate(to: "Override")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "Override")
    }

    func testCancel_neverLeavesEmpty() async {
        let state = TypewriterAnimationState(text: "preparedness", characterDelay: .milliseconds(20))
        state.animate(to: "New Title")
        try? await Task.sleep(for: .milliseconds(300))
        state.animate(to: "preparedness")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "preparedness")
    }

    // MARK: - Rapid Replacement

    func testRapidAnimateCalls_lastOneWins() async {
        let state = TypewriterAnimationState(text: "start", characterDelay: .milliseconds(1))
        state.animate(to: "aaa")
        state.animate(to: "bbb")
        state.animate(to: "ccc")
        await state.waitForCompletion()
        XCTAssertEqual(state.displayedText, "ccc")
    }

    // MARK: - Snap

    func testSnap_setsImmediately() {
        let state = TypewriterAnimationState(text: "old")
        state.snap(to: "new")
        XCTAssertEqual(state.displayedText, "new")
    }

    func testSnap_cancelsRunningAnimation() async {
        let state = TypewriterAnimationState(text: "long text here", characterDelay: .milliseconds(50))
        state.animate(to: "something")
        try? await Task.sleep(for: .milliseconds(50))
        state.snap(to: "snapped")
        XCTAssertEqual(state.displayedText, "snapped")
    }

    // MARK: - isAnimating (prevents toolbar layout collapse)

    func testIsAnimating_trueWhileRunning() async {
        let state = TypewriterAnimationState(text: "old", characterDelay: .milliseconds(50))
        XCTAssertFalse(state.isAnimating)
        state.animate(to: "new")
        XCTAssertTrue(state.isAnimating)
        await state.waitForCompletion()
        XCTAssertFalse(state.isAnimating)
    }

    func testIsAnimating_falseAfterSnap() async {
        let state = TypewriterAnimationState(text: "old", characterDelay: .milliseconds(50))
        state.animate(to: "new")
        XCTAssertTrue(state.isAnimating)
        state.snap(to: "snapped")
        XCTAssertFalse(state.isAnimating)
    }

    func testIsAnimating_falseAfterCancellation() async {
        let state = TypewriterAnimationState(text: "preparedness", characterDelay: .milliseconds(50))
        state.animate(to: "New Title")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.isAnimating)
        state.animate(to: "Final")
        // New animation is now running
        XCTAssertTrue(state.isAnimating)
        await state.waitForCompletion()
        XCTAssertFalse(state.isAnimating)
    }
}
