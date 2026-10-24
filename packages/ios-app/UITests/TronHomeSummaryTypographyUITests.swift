import XCTest

/// #1925: reading-family changes must not change Home's numeric stats font.
/// Measures the actual production card against shared code typography, not a
/// reported font name; proportional glyphs and line metrics must both match.
@MainActor final class TronHomeSummaryTypographyUITests: XCTestCase {
    func testHomeStatsUseSharedCodeTypographyAndScaleWithDynamicType() {
        continueAfterFailure = true
        var heights: [CGFloat] = []
        for largeType in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-summary-typography-fixture",
                                   "-fontFamily", "sourceSerif4", "-monoFontFamily", "jetBrainsMono",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                + (largeType ? ["-home-stats-large-type"] : [])
            app.launch()
            let actual = app.staticTexts["home-context-detail"]
            let reference = app.staticTexts["home-stats-code-reference"]
            XCTAssertTrue(actual.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(reference.exists, app.debugDescription)
            XCTAssertEqual(actual.label, reference.label, "Compare the same rendered stats, not unrelated text")
            let size = largeType ? "xxxLarge" : "large"
            let observed = "\(size): stats=\(actual.frame), code reference=\(reference.frame)"
            print("Home stats typography: \(observed)")
            XCTAssertEqual(actual.frame.width, reference.frame.width, accuracy: 0.5,
                           "Stats must use shared code glyph advances; \(observed)")
            XCTAssertEqual(actual.frame.height, reference.frame.height, accuracy: 0.5,
                           "Stats must use shared code line metrics; \(observed)")
            heights.append(actual.frame.height)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "1925-home-stats-code-\(size)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
        XCTAssertGreaterThan(heights[1], heights[0], "Home stats must grow with Dynamic Type")
    }
}
