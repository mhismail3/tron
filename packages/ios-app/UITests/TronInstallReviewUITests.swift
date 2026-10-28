import XCTest

final class TronInstallReviewUITests: XCTestCase {
    @MainActor func testOfferOpensOnlyInstallReview() throws { try assertSingleReview(play: false) }
    @MainActor func testPlayOpensOnlyInstallReview() throws { try assertSingleReview(play: true) }

    @MainActor private func assertSingleReview(play: Bool) throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let card = app.buttons["swiftApp.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), app.debugDescription)
        if play { card.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        else { card.tap() }
        XCTAssertTrue(app.scrollViews["apps.install.review"].waitForExistence(timeout: 20), app.debugDescription)
        // Dismiss so the passive observation on the presenting root is readable.
        app.navigationBars.firstMatch.swipeDown()
        let probe = app.otherElements["fixture.install-review-titles"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), app.debugDescription)
        let titles = probe.value as? String ?? ""
        let evidence = XCTAttachment(string: titles)
        evidence.name = "mounted-sheet-titles"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertFalse(titles.components(separatedBy: "|").contains("Builds"), "Transient runner chrome must never mount: \(titles)")
        XCTAssertEqual(titles.components(separatedBy: "|").filter { $0 == "Install App" }.count, 1, titles)
    }

    @MainActor func testToolbarInstallUsesReviewedOffer() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        try openReview(app)
        let install = app.navigationBars.buttons["apps.install.confirm"]
        XCTAssertEqual(install.label, "Install")
        XCTAssertEqual(app.buttons.matching(identifier: "apps.install.confirm").count, 1)
        XCTAssertFalse(app.buttons["apps.install.open"].exists)
        install.tap()
        XCTAssertTrue(app.buttons["apps.install.open"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(install.isEnabled, "Accepted installation must not be submitted twice")
    }

    @MainActor func testDetailsAndSourceLight() throws { try detailsJourney(dark: false, large: false) }
    @MainActor func testDetailsAndSourceDark() throws { try detailsJourney(dark: true, large: false) }
    @MainActor func testDetailsAndSourceLightXXXL() throws { try detailsJourney(dark: false, large: true) }
    @MainActor func testDetailsAndSourceDarkXXXL() throws { try detailsJourney(dark: true, large: true) }

    @MainActor private func detailsJourney(dark: Bool, large: Bool) throws {
        continueAfterFailure = false
        let app = launch(dark: dark, large: large)
        defer { app.terminate() }
        try openReview(app)
        let suffix = "\(dark ? "dark" : "light")\(large ? "-xxxl" : "")"
        capture(app, "main-\(suffix)")
        if large {
            let footer = app.staticTexts["Builds reads your iOS builds feed when opened."]
            for _ in 0..<8 {
                if footer.exists && footer.isHittable { break }
                app.scrollViews["apps.install.review"].swipeUp()
            }
            XCTAssertTrue(footer.isHittable, app.debugDescription)
            capture(app, "main-access-\(suffix)")
        }
        let info = app.buttons["apps.install.info"]
        XCTAssertTrue(info.isHittable, app.debugDescription)
        info.tap()
        let details = app.scrollViews["apps.install.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "details-\(suffix)")
        let source = app.buttons["apps.install.source"]
        for _ in 0..<6 {
            if source.exists && source.isHittable { break }
            details.swipeUp()
        }
        XCTAssertTrue(source.isHittable, app.debugDescription)
        capture(app, "details-source-row-\(suffix)")
        source.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Builds.swift"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let sourceReader = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Fixture app")).firstMatch
        XCTAssertTrue(sourceReader.waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func openReview(_ app: XCUIApplication) throws {
        let card = app.buttons["swiftApp.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), app.debugDescription)
        card.tap()
        let install = app.buttons["apps.install.confirm"]
        XCTAssertTrue(install.waitForExistence(timeout: 15), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: install)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func launch(dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-readonly-attachment-fixture", "-readonly-preview-scenario", "display-swift-install-review-inline-\(dark ? "dark" : "light")", "-tron.experimental.swiftApps", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-themeColor", "emerald"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }
}
