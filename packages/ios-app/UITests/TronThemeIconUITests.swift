import XCTest

/// Crosses the packaged asset/Info.plist and UIApplication alternate-icon boundary.
/// The fixture only reads native state; selections use the real Appearance view.
@MainActor final class TronThemeIconUITests: XCTestCase {
    func testThemeSelectionAppliesBundledIconsAndRestoresSilently() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-theme-icon-boundary"]
        app.launch()
        let initial = readNative(app)
        XCTAssertTrue(initial.contains("primary=AppIconBeta"), initial)
        let alternates = Set(initial.components(separatedBy: "alternates=").last!.split(separator: ",").map(String.init))
        XCTAssertEqual(alternates, ["AppIcon", "AppIconBurgundy", "AppIconOliveGold"], initial)
        // Finish at the hosted suite's default identity rather than leaking a
        // selected theme into later visual locks in this shared test app.
        let choices = [("burgundy", "AppIconBurgundy"), ("oliveGold", "AppIconOliveGold"), ("emerald", "AppIcon")]
        for (theme, icon) in choices {
            app.buttons["theme-icon-open-appearance"].tap()
            let row = app.buttons["theme-color-\(theme)"]
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            row.tap()
            dismissIconChangeAlert(app)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
            XCTAssertFalse(app.descendants(matching: .any)["theme-icon-error"].exists)
            XCTAssertEqual(row.value as? String, "Selected")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let state = readNative(app)
            XCTAssertTrue(state.contains("theme=\(theme);icon=\(icon);"), state)
            print("THEME_ICON_NATIVE \(state)")
        }
        let settled = readNative(app)
        app.buttons["theme-icon-open-appearance"].tap()
        app.buttons["theme-color-\(choices.last!.0)"].tap()
        XCTAssertFalse(iconChangeAlert(app).waitForExistence(timeout: 3), "Reselecting the applied icon must stay silent")
        let lightMode = app.buttons.matching(identifier: "Color Mode").element(boundBy: 0)
        lightMode.tap()
        XCTAssertTrue(lightMode.isSelected)
        XCTAssertFalse(iconChangeAlert(app).waitForExistence(timeout: 3), "Color mode must not change the app icon")
        let darkMode = app.buttons.matching(identifier: "Color Mode").element(boundBy: 1)
        darkMode.tap()
        XCTAssertTrue(darkMode.isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(readNative(app), settled)
        app.terminate()
        app.launch()
        XCTAssertEqual(readNative(app), settled, "Launch must preserve theme and the system's selected icon")
        XCTAssertFalse(iconChangeAlert(app).exists, "Restoring appearance must not request an icon change")
    }

    private func readNative(_ app: XCUIApplication) -> String {
        let read = app.buttons["theme-icon-read-native"]
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        return app.staticTexts["theme-icon-native-state"].label
    }

    private func iconChangeAlert(_ app: XCUIApplication) -> XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts
            .containing(NSPredicate(format: "label CONTAINS[c] 'changed the icon'")).firstMatch
    }

    private func dismissIconChangeAlert(_ app: XCUIApplication) {
        let alert = iconChangeAlert(app)
        if alert.waitForExistence(timeout: 3) {
            // This is Apple's icon-change acknowledgement, never a permission prompt.
            let ok = alert.buttons["OK"]
            XCTAssertTrue(ok.exists)
            ok.tap()
        }
    }
}
