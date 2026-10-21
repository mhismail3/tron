import XCTest

/// UI-port foreground regressions, added after personal native visual acceptance.
/// The synthetic Gateway is a real socket peer; UIKit lifetime, visible data,
/// read demand and post-reveal command admission are independent oracles.
final class TronForegroundCaptureUITests: XCTestCase {
    @MainActor func testHomeMemoryRetainsNativeStackAndPageLight() throws { try captureHome(dark: false) }
    @MainActor func testHomeMemoryRetainsNativeStackAndPageDark() throws { try captureHome(dark: true) }
    @MainActor func testHomeSettingsRefreshWithoutNativeReplayLight() throws { try captureHomeSettings(dark: false) }
    @MainActor func testHomeSettingsRefreshWithoutNativeReplayDark() throws { try captureHomeSettings(dark: true) }
    @MainActor func testRemovedSettingsRetiresOnlyInvalidChildDark() throws { try captureHomeSettings(dark: true, removed: true) }
    @MainActor func testProvidersRefreshWithoutNativeReplayLight() throws { try captureProviders(dark: false) }
    @MainActor func testProvidersRefreshWithoutNativeReplayDark() throws { try captureProviders(dark: true) }
    @MainActor func testSessionSettingsRefreshWithoutNativeReplayLight() throws { try captureSessionSettings(dark: false) }
    @MainActor func testSessionSettingsRefreshWithoutNativeReplayDark() throws { try captureSessionSettings(dark: true) }
    @MainActor func testQueuedEditorKeepsDraftAndValidatesRemovalLight() throws { try captureQueuedEditor(dark: false) }
    @MainActor func testQueuedEditorKeepsDraftAndValidatesRemovalDark() throws { try captureQueuedEditor(dark: true) }

    private struct Observation: Decodable {
        let stack: [String]
        let changes: Int
        let liveAnchors: Int
        let rpc: [String: Int]
        let frames: Int
        let foreground: Int
    }

    @MainActor private func observation(_ app: XCUIApplication) throws -> Observation {
        let probe = app.descendants(matching: .any)["fixture.foreground-native"].firstMatch
        let value = try XCTUnwrap(probe.value as? String, "Missing live native observation: \(app.debugDescription)")
        return try JSONDecoder().decode(Observation.self, from: Data(value.utf8))
    }

    @MainActor private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                      timeout: timeout) == .completed
    }

    @MainActor private func launch(_ dark: Bool, arguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-foreground-sheet-probe"]
            + arguments + (dark ? ["-home-dark"] : [])
        app.launch()
        let ready = arguments.contains("-dashboard-view-home")
            ? app.descendants(matching: .any)["home-usage-card"].firstMatch : app.buttons["home-pinned-row"]
        XCTAssertTrue(ready.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["fixture.foreground-native"].firstMatch.waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func captureHomeSettings(dark: Bool, removed: Bool = false) throws {
        continueAfterFailure = false
        let app = try launch(dark, arguments: ["-foreground-settings-change"] + (removed ? ["-foreground-settings-removed"] : []))
        defer { app.terminate() }
        let initial = try observation(app)
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 20))
        app.buttons["session-context-button"].tap()
        let settings = app.descendants(matching: .any)["home-manage-settings"].firstMatch
        reveal(settings, in: app); settings.tap()
        let models = app.buttons["settings-section-model-open"]
        XCTAssertTrue(models.waitForExistence(timeout: 20), app.debugDescription)
        reveal(models, in: app); models.tap()
        let thinking = app.buttons.matching(NSPredicate(format: "label == %@", "Worker thinking")).firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 20), app.debugDescription)
        reveal(thinking, in: app); thinking.tap()
        XCTAssertTrue(app.buttons["settings-option-Low"].waitForExistence(timeout: 20), app.debugDescription)
        try capture(app, name: "home-settings-\(removed ? "removed" : "choice")-\(dark ? "dark" : "light")",
                    reads: ["settings.resolve": 1, "settings.options": 2],
                    forbidden: ["session.open", "session.sync", "session.list", "provider.list", "home.context", "home.taskList"],
                    retiringTop: removed)
        if removed {
            XCTAssertFalse(app.buttons["settings-option-Low"].exists, "A removed schema row cannot retain its editor")
        } else {
            XCTAssertEqual(app.buttons["settings-option-High"].value as? String, "Selected", "The same mounted editor installs current server data")
        }
        for layer in (removed ? ["home-settings", "manage"] : ["models", "home-settings", "manage"]) {
            closeTop(app); markReveal(app, name: "\(layer)-\(dark ? "dark" : "light")")
        }
        app.buttons["home-sheet-done-manage"].tap(); app.buttons["Back"].tap()
        try finish(app, initial: initial, name: "settings-stack-retired")
    }

    @MainActor private func captureHome(dark: Bool) throws {
        continueAfterFailure = false
        let app = try launch(dark); defer { app.terminate() }
        let initial = try observation(app)
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 20))
        app.buttons["session-context-button"].tap()
        XCTAssertTrue(app.buttons["home-sheet-done-manage"].waitForExistence(timeout: 20))
        let memory = app.descendants(matching: .any)["home-manage-memory-browser"].firstMatch
        reveal(memory, in: app); memory.tap()
        XCTAssertTrue(app.buttons["home-sheet-done-memory"].waitForExistence(timeout: 20))
        let older = app.buttons["home-memory-older-top"]
        reveal(older, in: app); older.tap()
        let olderPage = app.descendants(matching: .any)["home-memory-summary-0-16"].firstMatch
        XCTAssertTrue(olderPage.waitForExistence(timeout: 20), app.debugDescription)
        reveal(olderPage, in: app)
        try capture(app, name: "memory-\(dark ? "dark" : "light")", reads: ["home.memory.view": 1],
                    forbidden: ["session.open", "session.sync", "session.list", "provider.list", "settings.resolve", "home.status", "home.taskList"])
        XCTAssertTrue(olderPage.isHittable, "Foreground preserves the current page, not merely a cached first page")
        app.buttons["home-memory-newer-top"].tap()
        let item = app.descendants(matching: .any)["home-memory-row-34"].firstMatch
        reveal(item, in: app)
        try capture(app, name: "memory-viewport-\(dark ? "dark" : "light")", reads: ["home.memory.view": 1],
                    forbidden: ["session.open", "session.sync", "session.list", "provider.list", "home.status", "home.taskList"])
        XCTAssertTrue(item.isHittable, "A compatible refresh preserves the scrolled native viewport")
        item.tap()
        XCTAssertTrue(app.buttons["home-sheet-done-memory-item"].waitForExistence(timeout: 20))
        try capture(app, name: "memory-item-\(dark ? "dark" : "light")", forbidden:
                        ["session.open", "session.sync", "session.list", "provider.list", "settings.resolve", "home.status", "home.taskList", "home.memory.view"])
        app.buttons["home-sheet-done-memory-item"].tap(); app.buttons["home-sheet-done-memory"].tap()
        try capture(app, name: "manage-revealed-\(dark ? "dark" : "light")",
                    reads: ["home.status": 1, "home.context": 1, "home.chapterList": 1, "home.profileList": 1, "home.taskList": 1],
                    forbidden: ["session.open", "session.sync", "session.list", "provider.list", "settings.resolve", "home.memory.view"])
        app.buttons["home-sheet-done-manage"].tap(); app.buttons["Back"].tap()
        try finish(app, initial: initial, name: "memory-stack-retired")
    }

    @MainActor private func captureProviders(dark: Bool) throws {
        continueAfterFailure = false
        let app = try launch(dark, arguments: ["-foreground-provider-change"]); defer { app.terminate() }
        let initial = try observation(app)
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["Settings"].tap()
        let providers = app.buttons["settings-link-Model Providers"]
        XCTAssertTrue(providers.waitForExistence(timeout: 20)); reveal(providers, in: app); providers.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Providers"].waitForExistence(timeout: 20), app.debugDescription)
        try capture(app, name: "providers-\(dark ? "dark" : "light")", reads: ["provider.list": 1, "model.list": 1],
                    forbidden: ["session.open", "session.sync", "session.list", "settings.resolve", "home.status", "home.taskList"])
        XCTAssertTrue(app.staticTexts["Fixture Refreshed"].exists, "The visible owner refreshes the catalog: \(app.debugDescription)")
        closeTop(app); app.buttons["settings-done"].tap(); app.buttons["Back"].tap()
        try finish(app, initial: initial, name: "providers-stack-retired")
    }

    @MainActor private func captureSessionSettings(dark: Bool) throws {
        continueAfterFailure = false
        let app = try launch(dark); defer { app.terminate() }
        let initial = try observation(app)
        let ordinary = app.buttons["session-row-home-shell-fixture:ordinary-session"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 20)); ordinary.tap()
        XCTAssertTrue(app.buttons["session-context-button"].waitForExistence(timeout: 20))
        app.buttons["session-context-button"].tap()
        let settings = app.buttons["chat-settings-link"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20)); reveal(settings, in: app); settings.tap()
        let connection = app.buttons["settings-section-advanced-open"]
        XCTAssertTrue(connection.waitForExistence(timeout: 20), app.debugDescription)
        reveal(connection, in: app); connection.tap()
        let transport = app.buttons.matching(NSPredicate(format: "label == %@", "Transport")).firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 20), app.debugDescription)
        reveal(transport, in: app); transport.tap()
        XCTAssertTrue(app.buttons["settings-option-Automatic"].waitForExistence(timeout: 20), app.debugDescription)
        try capture(app, name: "session-settings-choice-\(dark ? "dark" : "light")",
                    reads: ["session.open": 1, "session.sync": 1, "settings.resolve": 1, "settings.options": 2],
                    forbidden: ["provider.list", "session.list", "home.context", "home.taskList"])
        for _ in 0..<4 { closeTop(app) }
        app.buttons["Back"].tap()
        try finish(app, initial: initial, name: "session-settings-stack-retired")
    }

    @MainActor private func captureQueuedEditor(dark: Bool) throws {
        continueAfterFailure = false
        for removed in [false, true] {
            let app = try launch(dark, arguments: ["-foreground-queued-editor"] + (removed ? ["-foreground-queued-removed"] : []))
            defer { app.terminate() }
            let initial = try observation(app)
            app.buttons["home-pinned-row"].tap()
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Queued message 1607")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription); row.tap()
            let editor = app.textViews["Queued message"]
            XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
            editor.tap(); editor.typeText(" retained draft")
            XCTAssertTrue(app.keyboards.firstMatch.exists, "The retained-editor stimulus starts with keyboard focus")
            let draft = try XCTUnwrap(editor.value as? String)
            let caret = try XCTUnwrap(draft.range(of: " retained draft")?.upperBound)
            try capture(app, name: "queued-\(removed ? "removed" : "retained")-\(dark ? "dark" : "light")",
                        reads: ["session.open": 1, "session.sync": 1], forbidden: ["provider.list", "session.list", "settings.resolve"],
                        retiringTop: removed)
            if removed {
                XCTAssertFalse(editor.exists, "The authoritative queue removed this exact message")
            } else {
                XCTAssertEqual(editor.value as? String, draft, "A newer queue revision must not erase the local draft")
                XCTAssertTrue(app.keyboards.firstMatch.exists, "The native editor keeps its keyboard across foregrounding")
                // Type into the application's existing first responder without
                // tapping/refocusing any element; the exact editor must receive it.
                app.typeText(" focus survived")
                var expected = draft
                expected.insert(contentsOf: " focus survived", at: caret)
                XCTAssertEqual(editor.value as? String, expected, "The original editor keeps its first responder and insertion point")
                let title = app.navigationBars.staticTexts["Queued Message"].firstMatch
                title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            }
            app.buttons["Back"].tap()
            try finish(app, initial: initial, name: "queued-stack-retired")
            app.terminate()
        }
    }

    @MainActor func testDeferredCoveredSessionRegainsCommandAuthorityOnReveal() throws {
        continueAfterFailure = false
        let app = try launch(false); defer { app.terminate() }
        let initial = try observation(app)
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 20))
        try capture(app, name: "deferred-chat", forbidden: ["session.open", "session.sync", "session.list", "provider.list"])
        app.buttons["settings-done"].tap()
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20)); composer.tap(); composer.typeText("Reveal authority 1607")
        XCTAssertTrue(waitFor { app.buttons["Send message"].isEnabled }, "A revealed chat must re-subscribe and regain command admission")
        let revealed = try observation(app)
        XCTAssertEqual(revealed.rpc["session.open", default: 0] - initial.rpc["session.open", default: 0], 2,
                       "Initial chat open and exactly one deferred reveal restoration")
        XCTAssertEqual(revealed.rpc["session.sync", default: 0] - initial.rpc["session.sync", default: 0], 2)
        evidence(app, name: "deferred-chat-ready")
    }

    @MainActor func testDashboardUsageRefreshesItsVisibleProviderCatalog() throws {
        continueAfterFailure = false
        let app = try launch(false, arguments: ["-home-sheet-dashboard-workers", "-dashboard-view-home", "-foreground-provider-change"])
        defer { app.terminate() }
        let card = app.descendants(matching: .any)["home-usage-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(waitFor { card.label.contains("Anthropic, 42%") }, card.label)
        try capture(app, name: "dashboard-usage", reads: ["provider.list": 1, "model.list": 1],
                    forbidden: ["session.open", "session.sync"])
        XCTAssertTrue(card.label.contains("Anthropic Refreshed, 42%"), "Usage cannot keep a pre-disconnect provider catalog")
    }

    @MainActor func testConnectionsRefreshesVisibleAuthorizedDevicesWithoutWakingChat() throws {
        continueAfterFailure = false
        let app = try launch(false, arguments: ["-foreground-device-change"]); defer { app.terminate() }
        let initial = try observation(app)
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["Settings"].tap()
        let connection = app.buttons["settings-link-Connections"]
        XCTAssertTrue(connection.waitForExistence(timeout: 20)); reveal(connection, in: app); connection.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Connections"].waitForExistence(timeout: 20), app.debugDescription)
        try capture(app, name: "connections", reads: ["device.list": 1],
                    forbidden: ["session.open", "session.sync", "session.list", "provider.list", "home.taskList"])
        XCTAssertTrue(app.staticTexts["Foreground device"].exists, "The visible device owner refreshes after reconnect")
        closeTop(app); app.buttons["settings-done"].tap(); app.buttons["Back"].tap()
        try finish(app, initial: initial, name: "connections-stack-retired")
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String, reads: [String: Int] = [:],
                                    forbidden: [String] = [], retiringTop: Bool = false) throws {
        let before = try observation(app)
        XCTAssertGreaterThan(before.stack.count, 0)
        print("FOREGROUND_CAPTURE before \(name) \(Date().timeIntervalSince1970)")
        evidence(app, name: "\(name)-before")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 15))
        // A controlled background dwell is the stimulus, not a success oracle.
        Thread.sleep(forTimeInterval: 1)
        print("FOREGROUND_CAPTURE activate \(name) \(Date().timeIntervalSince1970)")
        app.activate()
        XCTAssertTrue(waitFor { ((try? self.observation(app).foreground) ?? before.foreground) > before.foreground },
                      "Foreground reconciliation must finish")
        let restored = try observation(app)
        XCTAssertTrue(waitFor { ((try? self.observation(app).frames) ?? 0) >= restored.frames + 120 },
                      "Observe 120 active display cycles, including late native replay")
        let after = try observation(app)
        let expectedStack = retiringTop ? Array(before.stack.dropLast()) : before.stack
        XCTAssertEqual(after.stack, expectedStack, "Existing native UIKit controllers must remain mounted")
        XCTAssertEqual(after.changes - before.changes, retiringTop ? 1 : 0,
                       "No transient native dismissal/re-presentation, even if the final screenshot matches")
        for (method, expected) in reads {
            XCTAssertEqual(after.rpc[method, default: 0] - before.rpc[method, default: 0], expected, "Bounded foremost read: \(method)")
        }
        for method in forbidden {
            XCTAssertEqual(after.rpc[method, default: 0] - before.rpc[method, default: 0], 0, "Covered read must wait for reveal: \(method)")
        }
        print("FOREGROUND_CAPTURE after \(name) \(Date().timeIntervalSince1970)")
        evidence(app, name: "\(name)-after")
    }

    @MainActor private func finish(_ app: XCUIApplication, initial: Observation, name: String) throws {
        XCTAssertTrue(waitFor { (try? self.observation(app).liveAnchors) == initial.liveAnchors },
                      "Closed native anchors must deinitialize, not retain their environment graphs")
        evidence(app, name: name)
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    @MainActor private func closeTop(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
            .allElementsBoundByIndex.first { $0.isHittable }
        guard let done else { return XCTFail("No top Done button: \(app.debugDescription)") }
        done.tap()
    }

    @MainActor private func markReveal(_ app: XCUIApplication, name: String) {
        print("REVEAL_CAPTURE \(name) \(Date().timeIntervalSince1970)")
        evidence(app, name: name)
    }

    @MainActor private func evidence(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        if let probe = try? observation(app),
           let data = try? JSONSerialization.data(withJSONObject: ["stack": probe.stack, "changes": probe.changes,
               "liveAnchors": probe.liveAnchors, "rpc": probe.rpc, "frames": probe.frames, "foreground": probe.foreground], options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            let native = XCTAttachment(string: text)
            native.name = "\(name)-native"; native.lifetime = .keepAlways; add(native)
        }
    }
}
