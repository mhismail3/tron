import XCTest
@testable import TronMobile

/// Tests for SheetCoordinator — lifecycle, callbacks, convenience methods
@MainActor
final class SheetCoordinatorLifecycleTests: XCTestCase {

    // MARK: - Present / Dismiss

    func testPresentSetsActiveSheet() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        XCTAssertEqual(coordinator.activeSheet, .settings)
        XCTAssertTrue(coordinator.isPresented)
    }

    func testDismissClearsActiveSheet() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.dismiss()
        XCTAssertNil(coordinator.activeSheet)
        XCTAssertFalse(coordinator.isPresented)
    }

    // MARK: - Replacement ownership

    func testReplacementDoesNotRetainPreviousSheetPayload() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.present(.thinkingDetail("details"))
        XCTAssertEqual(coordinator.activeSheet, .thinkingDetail("details"))
    }

    func testDismissRetainsNoSheetPayload() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.dismiss()
        XCTAssertNil(coordinator.activeSheet)
    }

    // MARK: - onDismiss Callback

    func testDismissCallsOnDismissCallback() {
        let coordinator = SheetCoordinator()
        var callbackFired = false
        coordinator.present(.settings) {
            callbackFired = true
        }
        coordinator.dismiss()
        XCTAssertTrue(callbackFired, "onDismiss callback should be called when dismiss() is invoked")
    }

    func testDismissNilsOutOnDismissAfterCalling() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings) { }
        coordinator.dismiss()
        XCTAssertNil(coordinator.onDismiss, "onDismiss should be cleared after dismissal")
    }

    func testDismissWithNilOnDismissDoesNotCrash() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.dismiss() // No onDismiss set — should not crash
    }

    // MARK: - Convenience Methods

    func testShowSettings() {
        let coordinator = SheetCoordinator()
        coordinator.showSettings()
        XCTAssertEqual(coordinator.activeSheet, .settings)
    }

    func testShowSessionContext() {
        let coordinator = SheetCoordinator()
        coordinator.showSessionContext()
        XCTAssertEqual(coordinator.activeSheet, .sessionContext)
    }

    func testShowThinkingDetail() {
        let coordinator = SheetCoordinator()
        coordinator.showThinkingDetail("Thinking")
        XCTAssertEqual(coordinator.activeSheet, .thinkingDetail("Thinking"))
    }

    func testUserInputWaitsForCurrentSheetThenPresents() throws {
        let coordinator = SheetCoordinator()
        let request = UserInputRequest(
            invocationId: "question-1",
            questions: [UserInputQuestion(
                header: "Format",
                id: "format",
                question: "Which format?",
                options: [
                    UserInputOption(label: "Markdown", description: "Markdown file"),
                    UserInputOption(label: "HTML", description: "HTML file")
                ]
            )],
            answers: [],
            status: .pending
        )
        coordinator.showSettings()

        coordinator.showUserInput(request)

        XCTAssertEqual(coordinator.activeSheet, .settings)
        coordinator.presentationDidDismiss()
        XCTAssertEqual(coordinator.activeSheet, .userInput(request))
    }

    func testResolvedUserInputDoesNotPresentAfterAnotherSheetDismisses() {
        let coordinator = SheetCoordinator()
        let request = UserInputRequest(
            invocationId: "question-1",
            questions: [],
            answers: [],
            status: .pending
        )
        coordinator.showSettings()
        coordinator.showUserInput(request)

        coordinator.clearUserInput()
        coordinator.presentationDidDismiss()

        XCTAssertNil(coordinator.activeSheet)
    }

}
