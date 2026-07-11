import XCTest

final class OnboardingSheetDetentUITests: XCTestCase {
    @MainActor
    func testOnboardingSheetHidesGrabberAndSupportsNativeExpansionGesture() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-incomplete")
        app.launch()

        let title = app.staticTexts["Welcome to Tron"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 20),
            "Onboarding should launch at its medium detent"
        )
        XCTAssertFalse(
            app.buttons["Sheet Grabber"].exists,
            "Tron sheets intentionally hide the system drag handle"
        )

        let initialTitleY = title.frame.minY
        app.swipeUp()

        let expanded = NSPredicate(
            block: { element, _ in
                guard let title = element as? XCUIElement else { return false }
                return title.frame.minY < initialTitleY - 100
            }
        )
        expectation(for: expanded, evaluatedWith: title)
        waitForExpectations(timeout: 5)
    }
}
