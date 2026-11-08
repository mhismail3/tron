import XCTest

/// Production Appearance persistence and shared section anatomy through a native app process.
@MainActor
final class TronAppearanceBehaviorUITests: XCTestCase {
    func testThemeSelectionPersistsAcrossProcessRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review"]
        app.launch()
        openAppearance(app)
        for theme in ["burgundy", "oliveGold", "emerald"] {
            let choice = app.buttons["theme-color-\(theme)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 8), "Appearance must expose all persisted identity choices")
            choice.tap()
            XCTAssertEqual(choice.value as? String, "Selected")
            assertThemeRow(app, selected: theme)
            app.terminate()
            app.launch()
            openAppearance(app)
            let restored = app.buttons["theme-color-\(theme)"]
            XCTAssertTrue(restored.waitForExistence(timeout: 8))
            XCTAssertEqual(restored.value as? String, "Selected", "A fresh process must read the saved choice, not a launch-default override")
        }
        app.terminate()
    }

    func testSingleSectionRetainsHeadingWithoutScreenOptIn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-controls-review"]
        app.launch()
        XCTAssertTrue(app.buttons["alignment.inherited"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["alignment.revert"].exists, "Rows and actions must survive heading suppression")
        XCTAssertTrue(app.staticTexts["Mixed controls"].exists, "A shared group retains its heading unless the screen opts in to hiding it")
        app.terminate()
    }

    func testSourceControlHeadingTracksActualContainerCount() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-new-session-fixture", "-new-session-scenario", "project-settings"]
        app.launch()
        let sourceControl = app.buttons["new-session-card.Source Control"]
        XCTAssertTrue(sourceControl.waitForExistence(timeout: 15))
        sourceControl.tap()
        let newBranch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Worktree · New Branch'")).firstMatch
        XCTAssertTrue(newBranch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Checkout Strategy"].exists, "A single checkout container needs no heading")
        newBranch.tap()
        XCTAssertTrue(app.staticTexts["New Branch"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Checkout Strategy"].exists, "Two real sections must retain both headings")
        app.terminate()
    }

    func testMultipleSectionsRetainTheirHeadings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review"]
        app.launch()
        openAppearance(app)
        XCTAssertTrue(app.staticTexts["Text Font"].exists, "Structural counting must retain headings on a multi-section page")
        app.terminate()
    }

    /// The three themes are one row of third-width tiles, each a 44pt+ target
    /// that VoiceOver reads as the theme's name with only the chosen one selected.
    private func assertThemeRow(_ app: XCUIApplication, selected: String) {
        let themes = [("emerald", "Emerald"), ("burgundy", "Deep Burgundy"), ("oliveGold", "Olive Gold")]
        let tiles = themes.map { app.buttons["theme-color-\($0.0)"] }
        let row = tiles[2].frame.maxX - tiles[0].frame.minX
        XCTAssertGreaterThan(row, app.windows.firstMatch.frame.width * 0.75, "The row spans the sheet's content width")
        for (index, tile) in tiles.enumerated() {
            let (id, name) = themes[index]
            XCTAssertTrue(tile.isHittable, "\(name) is visible without scrolling")
            XCTAssertEqual(tile.label, name)
            XCTAssertEqual(tile.isSelected, id == selected, "Only the chosen theme carries the selected trait")
            XCTAssertEqual(tile.value as? String ?? "", id == selected ? "Selected" : "")
            XCTAssertGreaterThanOrEqual(tile.frame.height, 44)
            XCTAssertEqual(tile.frame.width, (row - 20) / 3, accuracy: 1, "Each tile is a third of the row")
            XCTAssertEqual(tile.frame.minY, tiles[0].frame.minY, accuracy: 0.5, "Tiles share one horizontal row")
            if index > 0 { XCTAssertGreaterThan(tile.frame.minX, tiles[index - 1].frame.maxX) }
        }
    }

    private func openAppearance(_ app: XCUIApplication) {
        let open = app.buttons["Open Settings"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let appearance = app.buttons["Appearance"].firstMatch
        for _ in 0..<6 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.waitForExistence(timeout: 8))
        appearance.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Appearance"].waitForExistence(timeout: 8))
    }
}
