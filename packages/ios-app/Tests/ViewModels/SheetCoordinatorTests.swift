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
        coordinator.present(.userInteraction)
        XCTAssertEqual(coordinator.lastActiveSheet, .settings)
        XCTAssertEqual(coordinator.activeSheet, .userInteraction)
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

    func testShowUserInteraction() {
        let coordinator = SheetCoordinator()
        coordinator.showUserInteraction()
        XCTAssertEqual(coordinator.activeSheet, .userInteraction)
    }

}
