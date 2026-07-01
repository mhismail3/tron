import XCTest

final class DashboardHitTargetUITests: XCTestCase {
    @MainActor
    func testAgentBriefingBandVisibleEdgeOpensSheet() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--tron-ui-test-onboarding-complete")
        app.launch()

        let briefingBand = app.buttons["agent-briefing-dashboard-band"].firstMatch
        XCTAssertTrue(
            briefingBand.waitForExistence(timeout: 20),
            "Agent Briefing dashboard band should be visible above grouped sessions"
        )

        briefingBand.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()

        XCTAssertTrue(
            app.staticTexts["Agent Briefing"].waitForExistence(timeout: 10),
            "Tapping near the visible trailing edge of the Agent Briefing band should open its sheet"
        )
    }
}
