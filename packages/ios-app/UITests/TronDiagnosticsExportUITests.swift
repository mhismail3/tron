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
        let result = waitUntil(app.staticTexts["fixture.export-replacement"], NSPredicate(format: "label CONTAINS %@", "exports:1"), timeout: 3)
        evidence(app, "360-export-held-preparation-replacement")
        XCTAssertFalse(result, "Original diagnostics must never dispatch a file-writing export to the replacement Mac")
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
        XCTAssertFalse(waitUntil(app.staticTexts["fixture.export-original"], NSPredicate(format: "label CONTAINS %@", "exports:1"), timeout: 3), "Returning to the original profile cannot revive a retired command namespace")
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
    func testDismissedLogsCannotPublishHeldExportResult() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-diagnostics-export-fixture", "-diagnostics-export-scenario", "retirement"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(observe(app, "fixture.export-connection", "selected:export-original ready:true"))
        app.buttons["Open Logs"].tap()
        let export = app.buttons["Export Diagnostics"]
        XCTAssertTrue(export.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic-original-evidence")).firstMatch.waitForExistence(timeout: 15))
        export.tap()
        app.buttons["Close Logs"].tap()
        XCTAssertTrue(app.buttons["Open Logs"].waitForExistence(timeout: 15))
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:1 released:0"))
        let release = app.buttons["fixture.release-export-preparation"]
        XCTAssertTrue(waitUntil(release, NSPredicate(format: "hittable == true"), timeout: 15))
        release.tap()
        XCTAssertTrue(observe(app, "fixture.export-original", "exports:1 commands:1 repeats:0 originalEvidence:true"))
        XCTAssertFalse(waitUntil(app.staticTexts["fixture.export-notices"], NSPredicate(format: "label CONTAINS %@", "Diagnostics"), timeout: 2))
        XCTAssertFalse(app.buttons["Close"].exists)
        evidence(app, "1675-retired-export-publication")
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
    func testOlderRemoteFallbackCannotReplaceOrLeakLocalShareArtifact() {
        let app = launch("held-failure")
        defer { app.terminate() }
        app.buttons["Export Diagnostics"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:1 released:0"))
        app.buttons["Capture on iPhone"].tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "local:true"))
        evidence(app, "371-stale-remote-fallback-before-local-share-dismissal")
        close.tap()
        let remoteExport = app.buttons["Export Diagnostics"]
        XCTAssertTrue(waitUntil(remoteExport, NSPredicate(format: "hittable == true"), timeout: 5))
        XCTAssertFalse(remoteExport.isEnabled, "Dismissing local share must not release the older remote export's busy admission")
        XCTAssertTrue(observe(app, "fixture.export-original", "exports:0"))
        app.buttons["fixture.release-export-preparation"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:0 released:1"))
        XCTAssertTrue(observe(app, "fixture.export-original", "exports:1 commands:1 repeats:0"))
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "fallback-settled files:0"))
        XCTAssertFalse(app.buttons["Close"].exists, "The dismissed local share cannot be resurrected by the older fallback")
        app.buttons["fixture.inspect-export-artifacts"].tap()
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "files:0"))
    }

    @MainActor
    func testOlderLocalWriteFailureCannotPublishAfterNewerExportIntent() {
        let app = launch("local-held-failure")
        defer { app.terminate() }
        app.buttons["Capture on iPhone"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:1 released:0"))
        app.buttons["Export Diagnostics"].tap()
        XCTAssertTrue(observe(app, "fixture.export-original", "exports:1 commands:1 repeats:0 originalEvidence:true"))
        XCTAssertTrue(observe(app, "fixture.export-notices", "Diagnostics saved on Mac"))
        app.buttons["fixture.release-export-preparation"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:0 released:1"))
        XCTAssertTrue(waitUntil(app.buttons["Capture on iPhone"], NSPredicate(format: "enabled == true"), timeout: 15))
        XCTAssertFalse(waitUntil(app.staticTexts["fixture.export-notices"], NSPredicate(format: "label CONTAINS %@", "Local diagnostics could not be captured"), timeout: 3),
            "A real failed older local write cannot replace a newer export's successful intent")
        XCTAssertFalse(app.buttons["Close"].exists)
        evidence(app, "1732-superseded-local-write-failure")
    }

    @MainActor
    func testLocalArtifactReportsActualBoundedRowsAndWindow() {
        let app = launch("overflow")
        defer { app.terminate() }
        app.buttons["Capture on iPhone"].tap()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "local:true"))
        let artifactEvidence = app.staticTexts["fixture.export-artifacts"].label
        let fields = Dictionary(uniqueKeysWithValues: artifactEvidence.split(separator: " ").compactMap { item -> (String, String)? in
            let pair = item.split(separator: ":", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
        let selected = Int(fields["selected"] ?? "0") ?? 0
        let dropped = Int(fields["dropped"] ?? "0") ?? 0
        let rows = Int(fields["rows"] ?? "-1") ?? -1
        XCTAssertGreaterThan(selected, 0, artifactEvidence)
        XCTAssertGreaterThan(dropped, 0, artifactEvidence)
        XCTAssertEqual(selected, rows, artifactEvidence)
        XCTAssertEqual(fields["windowMatches"], "true", artifactEvidence)
        self.evidence(app, "371-local-artifact-actual-bounds")
    }

    @MainActor
    func testCaptureIgnoresVisibleFilterAndUnrelatedExportPreparation() {
        let app = launch("held")
        defer { app.terminate() }
        app.buttons["Export Diagnostics"].tap()
        XCTAssertTrue(observe(app, "fixture.export-preparation", "waiting:1 released:0"))
        app.buttons["Error"].tap()
        XCTAssertTrue(app.buttons["Capture on iPhone"].isEnabled)
        app.buttons["Capture on iPhone"].tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "local:true"))
        XCTAssertTrue(observe(app, "fixture.export-original", "exports:0"))
        evidence(app, "371-local-capture-independent-of-remote-export")
        close.tap()
    }

    @MainActor
    func testCaptureOnIPhoneDoesNotWaitForReadyGatewayLogRead() {
        let app = launch("logs-held")
        defer { app.terminate() }
        XCTAssertTrue(observe(app, "fixture.export-connection", "selected:export-original ready:true"))
        XCTAssertTrue(observe(app, "fixture.export-original", "logs:1 exports:0"))
        app.buttons["Capture on iPhone"].tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(observe(app, "fixture.export-original", "logs:1 exports:0"))
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "local:true"))
        evidence(app, "371-local-capture-during-held-gateway-read")
        close.tap()
        app.buttons["fixture.inspect-export-artifacts"].tap()
        app.buttons["Capture on iPhone"].tap()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Close"].tap()
        app.buttons["fixture.inspect-export-artifacts"].tap()
        XCTAssertTrue(observe(app, "fixture.export-artifacts", "files:0 local:false"))
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
        XCTAssertTrue(waitUntil(app.buttons["Export Diagnostics"], NSPredicate(format: "enabled == true"), timeout: 15))
        XCTAssertFalse(waitUntil(app.staticTexts["fixture.export-notices"], NSPredicate(format: "label CONTAINS %@", "Diagnostics"), timeout: 2), "Retired unsubmitted intent cannot publish a successor success or error")
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
            if scenario != "logs-held" {
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "synthetic-original-evidence")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            }
        }
        XCTAssertTrue(app.buttons["Export Diagnostics"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor
    private func observe(_ app: XCUIApplication, _ id: String, _ value: String) -> Bool {
        waitUntil(app.staticTexts[id], NSPredicate(format: "label CONTAINS %@", value), timeout: 15)
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
