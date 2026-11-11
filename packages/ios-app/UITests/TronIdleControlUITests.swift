import XCTest

final class TronIdleControlUITests: XCTestCase {
    @MainActor func testActualXCTestIdleControls() {
        runControls(["baseline", "orb", "covered-orb", "swiftui", "uikit"])
    }

    @MainActor func testBlockedMainThreadIdleCapture() {
        runControls(["blocked-main"])
    }

    @MainActor private func runControls(_ kinds: [String]) {
        continueAfterFailure = false
        for kind in kinds {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-idle-control", kind]
            app.launchEnvironment["TRON_UI_LOCK_RENDERING"] = "0"
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 10), app.debugDescription)
            let started = Date()
            app.buttons["Start"].tap()
            app.buttons["Probe"].tap()
            let state = app.staticTexts["fixture.idle-state"]
            XCTAssertTrue(state.label.hasSuffix("probes:1"), state.label)
            print("XCTEST_IDLE_CONTROL kind=\(kind) elapsed=\(Date().timeIntervalSince(started)) state=\(state.label)")
            app.terminate()
        }
    }
}
