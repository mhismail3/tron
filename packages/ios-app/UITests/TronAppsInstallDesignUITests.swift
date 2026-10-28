import XCTest

/// Native approval captures, not installed-app/transport acceptance. Both
/// sources run through the actual interpreter and shared runner sheet.
final class TronAppsInstallDesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLightDefaultReview() throws { try captureReview(dark: false, large: false) }
    @MainActor func testDarkDefaultReview() throws { try captureReview(dark: true, large: false) }
    @MainActor func testLightXXXLReview() throws { try captureReview(dark: false, large: true) }
    @MainActor func testDarkXXXLReview() throws { try captureReview(dark: true, large: true) }

    /// Existing production document surface, with a faux transport only. Main
    /// has Run but no Install App action; there is no former install-review screen.
    @MainActor func testCaptureSourceBeforeInstallReview() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BuildsPreview", withExtension: "swift", subdirectory: "builds-preview"))
        for dark in [false, true] {
            for large in [false, true] {
                let suffix = "\(dark ? "dark" : "light")-\(large ? "xxxl" : "default")"
                let app = XCUIApplication()
                app.launchEnvironment["TRON_HOSTED_SWIFT_APP_SOURCE"] = try String(contentsOf: url, encoding: .utf8)
                app.launchArguments = ["-tron-readonly-attachment-fixture", "-readonly-preview-scenario", "display-swift-builds-preview-\(dark ? "dark" : "light")", "-tron.experimental.swiftApps", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-themeColor", "emerald"]
                    + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
                app.launch()
                let display = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "BuildsPreview.swift")).firstMatch
                XCTAssertTrue(display.waitForExistence(timeout: 15), app.debugDescription)
                display.tap()
                XCTAssertTrue(app.buttons["Run BuildsPreview.swift"].waitForExistence(timeout: 10), app.debugDescription)
                capture("install-source-before-\(suffix)")
                app.terminate()
            }
        }
    }

    @MainActor private func captureReview(dark: Bool, large: Bool) throws {
        let suffix = "\(dark ? "dark" : "light")-\(large ? "xxxl" : "default")"
        for before in [true, false] {
            let phase = before ? "before" : "after"
            let app = XCUIApplication()
            let folder = "builds-preview"
            let file = before ? "BuildsPreview" : "BuildsInstallDesign"
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: file, withExtension: "swift", subdirectory: folder))
            app.launchEnvironment["TRON_APPS_DESIGN_SOURCE"] = try String(contentsOf: url, encoding: .utf8)
            app.launchArguments = ["-tron-apps-install-design-fixture", "-apps-design-expanded", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-themeColor", "emerald"]
                + (dark ? ["-apps-design-dark"] : [])
                + (before ? ["-apps-design-before"] : [])
                + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
            app.launch()
            let open = app.buttons["apps-install-design-open"]
            XCTAssertTrue(open.waitForExistence(timeout: 8), app.debugDescription)
            open.tap()
            let title = before ? "Tron builds" : "Builds"
            XCTAssertTrue(app.navigationBars.staticTexts[title].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            let first = app.staticTexts[before ? "Preview 3 #1163 + #1155" : "Apps installation and live builds"].firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 8), app.debugDescription)
            capture("builds-list-\(phase)-\(suffix)")
            for _ in 0..<3 {
                if first.isHittable { break }
                app.swipeUp()
            }
            if large { capture("builds-list-continued-\(phase)-\(suffix)") }
            first.tap()
            let install = app.buttons[before ? "Install" : "Install Build"]
            XCTAssertTrue(install.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertFalse(install.isEnabled, "Neither the historical source nor this visual proposal may install a build")
            capture("builds-detail-\(phase)-\(suffix)")
            app.swipeUp()
            capture("builds-detail-continued-\(phase)-\(suffix)")
            app.terminate()
        }

        let review = XCUIApplication()
        let sourceURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BuildsInstallDesign", withExtension: "swift", subdirectory: "builds-preview"))
        review.launchEnvironment["TRON_APPS_DESIGN_SOURCE"] = try String(contentsOf: sourceURL, encoding: .utf8)
        review.launchArguments = ["-tron-apps-install-design-fixture", "-apps-design-expanded", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-themeColor", "emerald"]
            + (dark ? ["-apps-design-dark"] : [])
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        review.launch()
        let button = review.buttons["apps-install-design-review"]
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        button.tap()
        XCTAssertTrue(review.navigationBars.staticTexts["Install App"].firstMatch.waitForExistence(timeout: 8))
        capture("install-review-after-\(suffix)")
        review.scrollViews["apps-install-design-review-scroll"].swipeUp()
        capture("install-review-continued-after-\(suffix)")
        if large {
            for page in 2...4 {
                review.scrollViews["apps-install-design-review-scroll"].swipeUp()
                capture("install-review-page-\(page)-after-\(suffix)")
            }
        }
        review.terminate()
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
