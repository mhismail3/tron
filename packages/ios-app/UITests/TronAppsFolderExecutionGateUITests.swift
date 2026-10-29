import XCTest

/// A readable source snapshot is not Apps membership or executable admission.
final class TronAppsFolderExecutionGateUITests: XCTestCase {
    @MainActor func testBareSwiftSnapshotNeverOffersExecutionEvenWithExperimentEnabled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-readonly-attachment-fixture", "-readonly-preview-scenario", "display-swift-unassociated",
                               "-tron.experimental.swiftApps", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let source = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Habits.swift'")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
        source.tap()
        let reader = app.textViews.matching(NSPredicate(format: "value BEGINSWITH 'import SwiftUI'")).firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "The immutable source remains readable")
        XCTAssertFalse(app.buttons["Run Habits.swift"].exists, "Only canonical Apps open can authorize a native runtime")
        XCTAssertFalse(app.staticTexts["habits.summary"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "apps-folder-bare-source-inert"; proof.lifetime = .keepAlways; add(proof)
    }
}
