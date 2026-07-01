import XCTest

final class OnboardingSheetDetentUITests: XCTestCase {
    @MainActor
    func testOnboardingGrabberExpandsMediumSheetToLarge() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-incomplete")
        app.launch()

        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(
            grabber.waitForExistence(timeout: 20),
            "The onboarding sheet should expose the native grabber at the medium detent"
        )
        XCTAssertEqual(
            grabber.value as? String,
            "Half screen",
            "Onboarding should launch at the medium detent"
        )

        grabber.doubleTap()

        let expanded = NSPredicate(format: "value == %@", "Expanded")
        expectation(for: expanded, evaluatedWith: grabber)
        waitForExpectations(timeout: 5)
    }
}
