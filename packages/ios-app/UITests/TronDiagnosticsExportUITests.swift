import XCTest

final class TronDiagnosticsExportUITests: XCTestCase {
    @MainActor
    func testPreparationCannotExportOriginalEvidenceToReplacementMac() {
        let app = launch("held")
        defer { app.terminate() }
        app.buttons["Export Diagnostics"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:1 released:0"))
        app.buttons["fixture.replace-export-profile"].tap()
        XCTAssertTrue(observe(app, "fixture.export-connection", "selected:export-replacement ready:true"))
        app.buttons["fixture.release-export-preparation"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:0 released:1"))
        let retargeted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "exports:1"), object: app.staticTexts["fixture.export-replacement"])
        let result = XCTWaiter.wait(for: [retargeted], timeout: 3)
        evidence(app, "360-export-held-preparation-replacement")
        XCTAssertEqual(result, .timedOut, "Original diagnostics must never dispatch a file-writing export to the replacement Mac")
        XCTAssertTrue(observe(app, "fixture.export-replacement", "exports:0 commands:0 repeats:0"))
        assertRetiredPreparationSettledSilently(app)
    }

    @MainActor
    func testReturningOriginalMacCannotReviveRetiredPreparation() {
        let app = launch("held")
        defer { app.terminate() }
        app.buttons["Export Diagnostics"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:1 released:0"))
        app.buttons["fixture.replace-export-profile"].tap()
        XCTAssertTrue(observe(app, "fixture.export-connection", "selected:export-replacement ready:true"))
        app.buttons["fixture.return-export-profile"].tap()
        XCTAssertTrue(observe(app, "fixture.export-connection", "selected:export-original ready:true"))
        app.buttons["fixture.release-export-preparation"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:0 released:1"))
        let revived = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "exports:1"), object: app.staticTexts["fixture.export-original"])
        XCTAssertEqual(XCTWaiter.wait(for: [revived], timeout: 3), .timedOut, "Returning to the original profile cannot revive a retired command namespace")
        XCTAssertTrue(observe(app, "fixture.export-replacement", "exports:0 commands:0 repeats:0"))
        assertRetiredPreparationSettledSilently(app)
        evidence(app, "360-export-retired-original-return")
    }

    @MainActor
    func testSameAuthorityForegroundRecoveryPreservesPreparedExport() {
        let app = launch("held")
        defer { app.terminate() }
        app.buttons["Export Diagnostics"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:1 released:0"))
        let priorConnection = app.staticTexts["fixture.export-connection"].label.components(separatedBy: "connection:").last!
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(observe(app, "fixture.export-connection", "selected:export-original ready:true"))
        XCTAssertFalse(app.staticTexts["fixture.export-connection"].label.hasSuffix("connection:" + priorConnection), "Foreground must actually replace the socket, not merely cover the leaf")
        app.buttons["fixture.release-export-preparation"].tap()
        XCTAssertTrue(observe(app, "fixture.export-original", "exports:1 commands:1 repeats:0 originalEvidence:true"))
        XCTAssertTrue(observe(app, "fixture.export-notices", "Diagnostics saved on Mac"))
        XCTAssertTrue(observe(app, "fixture.export-replacement", "exports:0 commands:0 repeats:0"))
        evidence(app, "360-export-same-authority-foreground")
    }

    @MainActor
    func testOriginalConnectedExportWritesOnceWithCapturedEvidence() {
        let app = launch("normal")
        defer { app.terminate() }
        app.buttons["Export Diagnostics"].tap()
        XCTAssertTrue(observe(app, "fixture.export-original", "exports:1 commands:1 repeats:0 originalEvidence:true"))
        XCTAssertTrue(observe(app, "fixture.export-notices", "Diagnostics saved on Mac"))
        XCTAssertTrue(observe(app, "fixture.export-replacement", "exports:0 commands:0 repeats:0"))
        evidence(app, "360-export-original-once")
    }

    @MainActor
    func testOfflineExportSharesOnceAndCancelDiscardsArtifact() {
        assertNativeShareAndCancel("offline", expectsRemoteFailure: false)
    }

    @MainActor
    func testFailedRemoteExportSharesWithoutRetryAndCancelDiscardsArtifact() {
        assertNativeShareAndCancel("failure", expectsRemoteFailure: true)
    }

    @MainActor
    private func assertNativeShareAndCancel(_ scenario: String, expectsRemoteFailure: Bool) {
        let app = launch(scenario)
        defer { app.terminate() }
        app.buttons["Export Diagnostics"].tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15), app.debugDescription)
        evidence(app, "360-export-\(scenario)-native-share")
        close.tap()
        app.buttons["fixture.inspect-export-artifacts"].tap()
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "files:0 local:false warnings:\(expectsRemoteFailure ? 1 : 0)"))
        XCTAssertTrue(observe(app, "fixture.export-original", "exports:\(expectsRemoteFailure ? 1 : 0) commands:\(expectsRemoteFailure ? 1 : 0) repeats:0"))
        // The one-artifact owner would reject preparation if native dismissal
        // had left the prior lease active. Initiate a second explicit gesture.
        app.buttons["Export Diagnostics"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 15), app.debugDescription)
        close.tap()
        app.buttons["fixture.inspect-export-artifacts"].tap()
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "files:0 local:false warnings:\(expectsRemoteFailure ? 2 : 0)"))
        evidence(app, "360-export-\(scenario)-cancel-cleanup")
    }

    @MainActor
    private func assertRetiredPreparationSettledSilently(_ app: XCUIApplication) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Export Diagnostics"])
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed)
        let staleNotice = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Diagnostics"), object: app.staticTexts["fixture.export-notices"])
        XCTAssertEqual(XCTWaiter.wait(for: [staleNotice], timeout: 2), .timedOut, "Retired unsubmitted intent cannot publish a successor success or error")
        XCTAssertFalse(app.buttons["Close"].exists, "Retired unsubmitted intent cannot open a successor share")
        app.buttons["fixture.inspect-export-artifacts"].tap()
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "files:0"))
    }

    @MainActor
    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-diagnostics-export-fixture", "-diagnostics-export-scenario", scenario]
        app.launch()
        if scenario != "offline" {
            XCTAssertTrue(observe(app, "fixture.export-connection", "selected:export-original ready:true"))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic-original-evidence")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        }
        XCTAssertTrue(app.buttons["Export Diagnostics"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor
    private func observe(_ app: XCUIApplication, _ id: String, _ value: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", value), object: app.staticTexts[id])], timeout: 15) == .completed
    }

    @MainActor
    private func evidence(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let trace = XCTAttachment(string: ["fixture.export-original", "fixture.export-replacement", "fixture.export-preparation", "fixture.export-connection", "fixture.export-artifacts"].map {
            let element = app.staticTexts[$0]
            return "\($0): \(element.exists ? element.label : "not-visible")"
        }.joined(separator: "\n"))
        trace.name = name + "-transport"; trace.lifetime = .keepAlways; add(trace)
    }
}
