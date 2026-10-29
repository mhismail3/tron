import XCTest
import CryptoKit

/// Production chat artifact → exact review → install → Apps → real interpreter,
/// using only the isolated fixture Gateway. Synthetic publisher files are never
/// opened by iOS: Install Build is inspected, not tapped or claimed installed.
extension RealGatewayPairAndChatUITests {
    @MainActor func testPendingAppReviewInstallLight() throws { try pendingAppJourney(dark: false) }
    @MainActor func testPendingAppReviewInstallDark() throws { try pendingAppJourney(dark: true) }

    @MainActor private func pendingAppJourney(dark: Bool) throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let root = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory)).deletingLastPathComponent()
        let appDirectory = root.appendingPathComponent("tron/workspace/state/apps/builds")
        let suffix = dark ? "dark" : "light"
        // Apps is independent of the chat-only Run Swift files experiment.
        let app = launchApp(additionalArguments: ["-appearanceMode", suffix, "-tron.experimental.swiftApps", "NO"])
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        try buildsPrompt(app, "BUILDS-APP-JOURNEY")
        XCTAssertTrue(app.staticTexts["Builds app ready for review."].firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        // Leave the producing chat without ever opening its inline offer card.
        app.buttons["Back"].tap()
        buildsOpenApps(app)
        let pending = app.buttons["pending-app-row-builds"]
        XCTAssertTrue(pending.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.buttons["installed-app-row-builds"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDirectory.path), "Listing an offer must not install")
        keepScreenshot(app, name: "2104-apps-pending-\(suffix)")
        pending.tap()
        let review = app.scrollViews["apps.install.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Read-only feed"].firstMatch.exists, app.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDirectory.path), "Opening review must not install")
        keepScreenshot(app, name: "2104-pending-review-\(suffix)")
        app.buttons["apps.install.info"].tap()
        let details = app.scrollViews["apps.install.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), app.debugDescription)
        buildsReveal(app, app.buttons["apps.install.source"], in: details)
        keepScreenshot(app, name: "2104-pending-review-source-\(suffix)")
        app.buttons["apps.install.source"].tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.navigationBars.staticTexts["App.swift"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        keepScreenshot(app, name: "2104-pending-source-\(suffix)")
        buildsClose(app)
        buildsClose(app)
        buildsReveal(app, app.buttons["apps.install.confirm"], in: review)
        keepScreenshot(app, name: "2104-pending-review-confirm-\(suffix)")
        app.buttons["apps.install.confirm"].tap()
        XCTAssertTrue(app.buttons["apps.install.open"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appDirectory.appendingPathComponent("app.json").path), "Only explicit confirmation installs")
        let reviewBar = app.navigationBars.containing(.button, identifier: "apps.install.confirm").firstMatch
        reviewBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        let installed = app.buttons["installed-app-row-builds"]
        XCTAssertTrue(installed.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(pending.exists, "Installed app must leave Pending")
        keepScreenshot(app, name: "2104-apps-installed-\(suffix)")
        buildsClose(app)
        buildsOpenApps(app)
        XCTAssertTrue(installed.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(pending.exists, "Authoritative reload must keep it installed, not pending")
    }

    @MainActor func testBuildsInstallLight() throws { try buildsJourney(dark: false, large: false) }
    @MainActor func testBuildsInstallDark() throws { try buildsJourney(dark: true, large: false) }
    @MainActor func testBuildsInstallLightXXXL() throws { try buildsJourney(dark: false, large: true) }
    @MainActor func testBuildsInstallDarkXXXL() throws { try buildsJourney(dark: true, large: true) }

    @MainActor private func buildsJourney(dark: Bool, large: Bool) throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let root = URL(fileURLWithPath: try XCTUnwrap(fixture.agentDirectory)).deletingLastPathComponent()
        let tron = root.appendingPathComponent("tron")
        let appDirectory = tron.appendingPathComponent("workspace/state/apps/builds")
        let sourceURL = URL(fileURLWithPath: fixture.workspace).appendingPathComponent("Builds.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        try seedBuild(tron: tron, second: false)
        let suffix = "\(dark ? "dark" : "light")-\(large ? "xxxl" : "default")"
        let app = launchApp(additionalArguments: ["-appearanceMode", dark ? "dark" : "light", "-tron.experimental.swiftApps", "YES"]
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []))
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        XCTAssertTrue(waitForHittable(app.buttons["dashboard.menu"], timeout: 90), app.debugDescription)
        createSession(app, inWorkspace: fixture.workspace)
        try buildsPrompt(app, "BUILDS-APP-JOURNEY")
        let card = app.buttons["swiftApp.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), app.debugDescription)
        let originalOffer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: offeredSourceURL(tron: tron, source: source))) as? [String: Any])
        let originalReference = try XCTUnwrap(originalOffer["reference"] as? [String: String])
        let originalSessionID = try XCTUnwrap(originalReference["sessionId"])
        keepScreenshot(app, name: "1162-offer-\(suffix)")
        card.tap()
        let review = app.scrollViews["apps.install.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDirectory.path), "Review must not install")
        keepScreenshot(app, name: "1162-install-review-\(suffix)")
        buildsReveal(app, app.buttons["apps.install.confirm"], in: review, capturePrefix: large ? "1162-install-scroll-\(suffix)" : nil)
        keepScreenshot(app, name: "1162-install-review-continued-\(suffix)")
        app.buttons["apps.install.confirm"].tap()
        let openApp = app.buttons["apps.install.open"]
        XCTAssertTrue(openApp.waitForExistence(timeout: 30), app.debugDescription)
        openApp.tap()
        let first = app.staticTexts["First fixture build"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), app.debugDescription)
        keepScreenshot(app, name: "1162-live-list-\(suffix)")
        buildsReveal(app, first)
        first.tap()
        let installBuild = app.buttons["Install Build"]
        XCTAssertTrue(installBuild.waitForExistence(timeout: 20) && installBuild.isEnabled, app.debugDescription)
        keepScreenshot(app, name: "1162-live-detail-\(suffix)")
        // Do not tap Install Build: that would leave the hermetic UI boundary.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let query = app.textFields["Title, branch or commit"]
        buildsReveal(app, query)
        query.tap(); query.typeText("fixture")
        buildsClose(app)
        app.buttons["Back"].tap()
        buildsOpenApps(app)
        let row = app.buttons["installed-app-row-builds"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        row.tap()
        XCTAssertTrue(query.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(query.value as? String, "fixture", "AppStorage must survive reopen")
        try seedBuild(tron: tron, second: true)
        // Native List pull-to-refresh must obtain a new Gateway feed without a
        // source reinstall, keeping the persisted search intact.
        let liveList = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.first(where: { $0.isHittable }))
        liveList.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.35)).press(forDuration: 0.1,
            thenDragTo: liveList.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)),
            withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.staticTexts["Second fixture build"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(query.value as? String, "fixture")
        keepScreenshot(app, name: "1162-refreshed-list-\(suffix)")
        buildsClose(app)
        row.press(forDuration: 1)
        app.buttons["Manage"].tap()
        XCTAssertTrue(app.buttons["installed-app-manage-remove"].waitForExistence(timeout: 20), app.debugDescription)
        keepScreenshot(app, name: "1162-manage-before-update-\(suffix)")
        if large {
            buildsReveal(app, app.buttons["installed-app-manage-remove"])
            app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable })?.swipeUp()
            keepScreenshot(app, name: "1162-manage-before-update-continued-\(suffix)")
        }
        buildsClose(app); buildsClose(app)
        createSession(app, inWorkspace: fixture.workspace)
        try (source + "\n// explicit reviewed update\n").write(to: sourceURL, atomically: true, encoding: .utf8)
        try buildsPrompt(app, "BUILDS-APP-JOURNEY UPDATE")
        XCTAssertTrue(card.waitForExistence(timeout: 60), app.debugDescription)
        card.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 30), app.debugDescription)
        keepScreenshot(app, name: "1162-update-review-\(suffix)")
        buildsReveal(app, app.buttons["apps.install.confirm"], in: review, capturePrefix: large ? "1162-update-scroll-\(suffix)" : nil)
        keepScreenshot(app, name: "1162-update-review-continued-\(suffix)")
        app.buttons["apps.install.confirm"].tap()
        XCTAssertTrue(openApp.waitForExistence(timeout: 30), app.debugDescription)
        openApp.tap()
        XCTAssertTrue(query.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(query.value as? String, "fixture", "Update App must preserve data")
        buildsClose(app)
        app.buttons["Back"].tap()
        createSession(app, inWorkspace: fixture.workspace)
        let errorSource = source + "\n// rejected stale-offer fixture\n"
        try errorSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        try buildsPrompt(app, "BUILDS-APP-JOURNEY UPDATE ERROR")
        XCTAssertTrue(card.waitForExistence(timeout: 60), app.debugDescription)
        card.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 30), app.debugDescription)
        let offerURL = try offeredSourceURL(tron: tron, source: errorSource)
        var offer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: offerURL)) as? [String: Any])
        offer["name"] = "Changed after review"
        try JSONSerialization.data(withJSONObject: offer).write(to: offerURL, options: .atomic)
        buildsReveal(app, app.buttons["apps.install.confirm"], in: review)
        keepScreenshot(app, name: "1162-error-before-confirm-\(suffix)")
        app.buttons["apps.install.confirm"].tap()
        let failure = app.otherElements["apps.install.error"].firstMatch
        let failureText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Installation was not confirmed")).firstMatch
        XCTAssertTrue(failureText.waitForExistence(timeout: 30), app.debugDescription)
        buildsReveal(app, failure.exists ? failure : failureText, in: review)
        keepScreenshot(app, name: "1162-update-error-\(suffix)")
        review.swipeUp()
        keepScreenshot(app, name: "1162-update-error-detail-\(suffix)")
        if large {
            review.swipeUp()
            keepScreenshot(app, name: "1162-update-error-end-\(suffix)")
        }
        XCTAssertFalse(app.buttons["apps.install.confirm"].isEnabled, "A failed accepted command cannot be replaced on another tap")
        buildsClose(app)
        app.buttons["Back"].tap()
        buildsOpenApps(app)
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        row.press(forDuration: 1); app.buttons["Manage"].tap()
        let remove = app.buttons["installed-app-manage-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 20), app.debugDescription)
        keepScreenshot(app, name: "1162-manage-after-update-\(suffix)")
        buildsReveal(app, remove)
        if large { app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable })?.swipeUp() }
        keepScreenshot(app, name: "1162-manage-after-update-continued-\(suffix)")
        remove.tap()
        let confirm = app.buttons["Remove App"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No apps are installed on this Mac yet. Ask Tron to build one and install it."].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDirectory.path), "Remove must remove source and data")
        if !dark && !large {
            // Revisit the SAME completed offer. A retained success must not
            // replace fresh consent with Open after this instance was removed.
            buildsClose(app)
            let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "session-row-", ":\(originalSessionID)")).firstMatch
            for _ in 0..<4 {
                if original.exists { break }
                app.collectionViews.firstMatch.swipeDown()
            }
            buildsReveal(app, original); original.tap()
            XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription); card.tap()
            XCTAssertTrue(review.waitForExistence(timeout: 30), app.debugDescription)
            buildsReveal(app, app.buttons["apps.install.confirm"], in: review)
            XCTAssertTrue(app.buttons["apps.install.confirm"].isEnabled, "Removal must permit a fresh explicit installation of this same offer")
            app.buttons["apps.install.confirm"].tap()
            XCTAssertTrue(openApp.waitForExistence(timeout: 30), app.debugDescription); openApp.tap()
            XCTAssertTrue(query.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertNotEqual(query.value as? String, "fixture", "Reinstallation must create fresh app data")
            keepScreenshot(app, name: "1162-reinstalled-after-remove-\(suffix)")
            buildsClose(app); app.buttons["Back"].tap(); buildsOpenApps(app)
            XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
            row.press(forDuration: 1); app.buttons["Manage"].tap()
            buildsReveal(app, remove); remove.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription); confirm.tap()
            XCTAssertTrue(app.staticTexts["No apps are installed on this Mac yet. Ask Tron to build one and install it."].waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(FileManager.default.fileExists(atPath: appDirectory.path), "Fixture reinstallation must be removed too")
        }
    }

    private func offeredSourceURL(tron: URL, source: String) throws -> URL {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = tron.appendingPathComponent("workspace/state/apps/.offers")
        let offered = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { directory in
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("offer.json"))) as? [String: Any]
            return record?["sourceSha256"] as? String == digest
        }
        return try XCTUnwrap(offered).appendingPathComponent("offer.json")
    }

    private func seedBuild(tron: URL, second: Bool) throws {
        let id = "20261028T\(second ? "090000" : "080000")Z-\(second ? String(repeating: "b", count: 32) : String(repeating: "a", count: 32))-abcdef012"
        let root = tron.appendingPathComponent("ios-builds")
        let directory = root.appendingPathComponent("builds/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent(".publish.lock")
        if !FileManager.default.fileExists(atPath: lock.path) { try Data().write(to: lock) }
        let ipa = Data(repeating: 1, count: 32)
        try ipa.write(to: directory.appendingPathComponent("TronMobile.ipa"))
        let record: [String: Any] = ["id": id, "title": "\(second ? "Second" : "First") fixture build", "notes": "Synthetic test build. Do not install this fixture. Read its full metadata and check refresh.",
            "commit": String(repeating: "a", count: 40), "branch": "feature/builds", "mode": "optimized", "time": "2026-10-28T\(second ? "09" : "08"):00:00+00:00",
            "sha256": String(repeating: "b", count: 64), "bytes": ipa.count, "bundle_id": "com.tron.mobile"]
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("build.json"))
        let manifest: [String: Any] = ["items": [["assets": [["kind": "software-package", "url": "https://127.0.0.1:8443/builds/\(id)/TronMobile.ipa"]],
            "metadata": ["bundle-identifier": "com.tron.mobile", "bundle-version": "1.0", "kind": "software", "title": "Fixture"]]]]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: directory.appendingPathComponent("manifest.plist"))
    }

    @MainActor private func buildsPrompt(_ app: XCUIApplication, _ text: String) throws {
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
        composer.tap(); composer.typeText(text)
        XCTAssertTrue(waitForEnabled(app.buttons["Send message"], timeout: 30), app.debugDescription)
        app.buttons["Send message"].tap()
    }
    @MainActor private func buildsClose(_ app: XCUIApplication) {
        let done = app.buttons.matching(identifier: "Done")
        XCTAssertTrue(done.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        (done.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? done.firstMatch).tap()
    }
    @MainActor private func buildsOpenApps(_ app: XCUIApplication) {
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(waitForHittable(menu, timeout: 30), app.debugDescription)
        if menu.label == "Home" { menu.press(forDuration: 0.6) } else { menu.tap() }
        XCTAssertTrue(app.buttons["Apps"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Apps"].tap()
    }
    @MainActor private func buildsReveal(_ app: XCUIApplication, _ element: XCUIElement, in scroll: XCUIElement? = nil, capturePrefix: String? = nil) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), app.debugDescription)
        let container = scroll
            ?? app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable })
            ?? app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable })
            ?? app
        for step in 0..<12 {
            if element.isHittable { break }
            container.swipeUp()
            if let capturePrefix { keepScreenshot(app, name: "\(capturePrefix)-\(step + 1)") }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
}
