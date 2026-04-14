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

    // MARK: - lastActiveSheet

    func testLastActiveSheetTrackedOnPresent() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.present(.agentControl)
        XCTAssertEqual(coordinator.lastActiveSheet, .settings)
        XCTAssertEqual(coordinator.activeSheet, .agentControl)
    }

    func testLastActiveSheetTrackedOnDismiss() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.dismiss()
        XCTAssertEqual(coordinator.lastActiveSheet, .settings)
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

    func testShowAgentControl() {
        let coordinator = SheetCoordinator()
        coordinator.showAgentControl()
        XCTAssertEqual(coordinator.activeSheet, .agentControl)
    }

    func testShowSessionHistory() {
        let coordinator = SheetCoordinator()
        coordinator.showSession()
        XCTAssertEqual(coordinator.activeSheet, .session)
    }

    func testShowAskUserQuestion() {
        let coordinator = SheetCoordinator()
        coordinator.showAskUserQuestion()
        XCTAssertEqual(coordinator.activeSheet, .askUserQuestion)
    }

    func testShowGetConfirmation() {
        let coordinator = SheetCoordinator()
        coordinator.showGetConfirmation()
        XCTAssertEqual(coordinator.activeSheet, .getConfirmation)
    }

    func testShowSubagentDetail() {
        let coordinator = SheetCoordinator()
        coordinator.showSubagentDetail()
        XCTAssertEqual(coordinator.activeSheet, .subagentDetail)
    }

    func testShowSubagentResultsList() {
        let coordinator = SheetCoordinator()
        coordinator.showSubagentResultsList()
        XCTAssertEqual(coordinator.activeSheet, .subagentResultsList)
    }
}
