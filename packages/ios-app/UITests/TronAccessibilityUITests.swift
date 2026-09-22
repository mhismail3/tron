import XCTest

/// SwiftUI semantics are queried through XCTest's real accessibility client,
/// not uninitialized NSObject proxies in a hosted unit-test process.
@MainActor
final class TronAccessibilityUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        return app
    }

    func testServerInfoRowsAndDone() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["Gateway Server Info"].tap()
        for label in ["Machine, Mac", "Gateway, 1", "Agent runtime, 2", "Protocol, 5",
                      "Restart supervision, Managed LaunchAgent", "Source revision, source-revision",
                      "Runtime epoch, runtime-epoch", "Payload identity, payload-identity"] {
            XCTAssertTrue(app.staticTexts[label].firstMatch.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertFalse(app.buttons[label].exists, "Facts are not navigation targets")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "Done").count, 1)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Gateway Server Info"].isHittable)
    }

    func testMaintenanceActionGeometry() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["Maintenance"].tap()
        let labels = ["Rebuild from Source", "Roll Back", "Restart", "Disable", "Forget Server"]
        for label in labels { XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3)) }
        let frames = labels.map { app.buttons[$0].frame }
        XCTAssertEqual(frames[0].minX, frames[2].minX, accuracy: 1)
        XCTAssertEqual(frames[1].minX, frames[3].minX, accuracy: 1)
        XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
        XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
        XCTAssertEqual(frames[2].minY, frames[3].minY, accuracy: 1)
        XCTAssertGreaterThan(frames[2].minY, frames[0].maxY)
        XCTAssertGreaterThan(frames[4].width, frames[0].width * 1.5)
        XCTAssertGreaterThan(frames[4].minY, frames[2].maxY)
        // Never invoke lifecycle actions: these are inert fixture closures.
    }

    func testJSONTypedButtonsOpenTheirCompleteValues() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["Structured JSON"].tap()
        for label in ["Active Async Capacity, Object, 2 fields", "Mode, Text, single", "Results, List, 0 items"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), app.debugDescription)
        }
        XCTAssertTrue(app.staticTexts["DETAILS"].exists)
        // XCUI exposes label/value/type, not accessibilityHint. Verify the
        // promised action itself rather than incorrectly treating hint as label.
        app.buttons["Active Async Capacity, Object, 2 fields"].tap()
        XCTAssertTrue(app.buttons["Max, Number, 4"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Mode, Text, single"].exists)
    }

    func testActivityValuesUpdateInTheSamePresentedSheet() {
        for arguments in [[], ["-fixture-light", "-fixture-large-type"]] {
            let app = launch(arguments)
            defer { app.terminate() }
            app.buttons["Session Activity"].tap()
            let row = app.buttons["worker"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), app.debugDescription)
            waitForValue("LIVE OUTPUT: Inspecting the source files.", in: row)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "worker")).count, 1)
            XCTAssertTrue((row.value as? String)?.contains("Asynchronous") == true)
            XCTAssertGreaterThan(row.frame.width, 0)
            XCTAssertGreaterThanOrEqual(row.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(row.frame.maxX, app.frame.maxX)
            let scroll = app.scrollViews.allElementsBoundByIndex.first { $0.isHittable }!
            let originalFrame = scroll.frame

            app.buttons["Update fixture output"].tap()
            waitForValue("Latest check passed.", in: row)
            XCTAssertFalse((row.value as? String)?.contains("Inspecting the source files.") == true)
            XCTAssertFalse((row.value as? String)?.contains("Old output") == true)
            XCTAssertTrue((row.value as? String)?.contains("First check passed.") == true)
            XCTAssertEqual(scroll.frame, originalFrame, "Output must not resize the selected sheet detent")

            app.buttons["Finish fixture output"].tap()
            waitForValue("RESULT: All focused checks passed.", in: row)
            XCTAssertTrue((row.value as? String)?.contains("Completed") == true)
            XCTAssertFalse((row.value as? String)?.contains("LIVE OUTPUT") == true)
            XCTAssertEqual(scroll.frame, originalFrame)
        }
    }

    func testDashboardHeaderFramesAndNativeMenuOrder() {
        for arguments in [[], ["-fixture-light", "-fixture-large-type"]] {
            let app = launch(["-fixture-dashboard"] + arguments)
            defer { app.terminate() }
            let title = app.staticTexts["Tron"]
            XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.buttons["Tron"].exists)
            let expanded = title.frame
            XCTAssertLessThan(expanded.midX, app.frame.midX)
            let menu = app.buttons["dashboard.menu"]
            let menuFrame = menu.frame
            XCTAssertEqual(menuFrame.width, 56, accuracy: 1)
            XCTAssertEqual(menuFrame.height, 56, accuracy: 1)
            XCTAssertGreaterThan(menuFrame.midX, app.frame.midX)
            XCTAssertGreaterThan(menuFrame.midY, app.frame.height * 0.8)
            XCTAssertFalse(app.buttons["Search sessions"].exists)
            menu.tap()
            let titles = ["Settings", "Filter", "Search", "Sessions", "Automations", "Knowledge", "New Session"]
            for label in titles { XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3)) }
            let frames = titles.map { app.buttons[$0].frame }
            for (before, after) in zip(frames, frames.dropFirst()) { XCTAssertLessThan(before.midY, after.midY) }
            XCTAssertLessThanOrEqual(frames.last!.maxY, menuFrame.maxY + 1)
            app.buttons["Sessions"].tap()
            let scroll = app.collectionViews.firstMatch
            let viewport = scroll.frame
            app.buttons["Scroll 40"].tap()
            waitForFrame(title, y: expanded.minY - 12.5, height: expanded.height * 33 / 34)
            XCTAssertEqual(title.frame.minY, expanded.minY - 12.5, accuracy: 1)
            XCTAssertEqual(title.frame.height / expanded.height, 33.0 / 34, accuracy: 0.015)
            app.buttons["Scroll 120"].tap()
            waitForFrame(title, y: expanded.minY - 25, height: expanded.height * 32 / 34)
            XCTAssertEqual(title.frame.minY, expanded.minY - 25, accuracy: 1)
            XCTAssertEqual(title.frame.minX, expanded.minX, accuracy: 1)
            XCTAssertEqual(title.frame.height / expanded.height, 32.0 / 34, accuracy: 0.015)
            XCTAssertEqual(scroll.frame, viewport)
            XCTAssertEqual(menu.frame, menuFrame)
            app.buttons["Scroll -120"].tap()
            waitForFrame(title, y: expanded.minY, height: expanded.height * 1.06)
            XCTAssertEqual(title.frame.minY, expanded.minY, accuracy: 1)
            XCTAssertEqual(title.frame.minX, expanded.minX, accuracy: 1)
            XCTAssertEqual(title.frame.height / expanded.height, 1.06, accuracy: 0.015)
            app.buttons["Scroll 0"].tap()
            waitForFrame(title, y: expanded.minY, height: expanded.height)
            XCTAssertEqual(title.frame.height, expanded.height, accuracy: 0.5)
            XCTAssertEqual(title.frame.minY, expanded.minY, accuracy: 0.5)
            // Exercise UIKit's actual gesture/release, not an animated command
            // issued while a fixture has forced an out-of-range contentOffset.
            scroll.swipeDown()
            waitForFrame(title, y: expanded.minY, height: expanded.height)
            XCTAssertEqual(scroll.frame, viewport)
            XCTAssertEqual(menu.frame, menuFrame)
        }
    }

    func testDashboardActionsPresentTheirExistingDestinations() {
        let destinations = [
            ("Sessions", "Filter", "Filter Servers"), ("Sessions", "Settings", "Settings"),
            ("Sessions", "New Session", "New Session"),
            ("Automations", "Filter", "View Automations"), ("Automations", "Settings", "Settings"),
            ("Automations", "Choose agenda date", "Jump to date"), ("Automations", "Create Automation", "New Automation"),
            ("Knowledge", "Filter", "Knowledge filters"), ("Knowledge", "Settings", "Settings"),
            ("Knowledge", "Observation configuration", "Observation"), ("Knowledge", "Connectors", "Connectors"),
            ("Knowledge", "Import legacy records", "Import Knowledge"), ("Knowledge", "Capture URL", "Capture URL"),
            ("Knowledge", "New note", "New note"),
        ]
        for (mode, action, expected) in destinations {
            let app = launch(["-fixture-dashboard"])
            defer { app.terminate() }
            select(mode, in: app)
            app.buttons["dashboard.menu"].tap()
            if ["Observation configuration", "Connectors", "Import legacy records"].contains(action) {
                app.buttons["Knowledge settings"].tap()
            }
            app.buttons[action].tap()
            XCTAssertTrue(app.staticTexts[expected].firstMatch.waitForExistence(timeout: 3), "\(mode)/\(action): \(app.debugDescription)")
            XCTAssertTrue(app.navigationBars.firstMatch.exists)
        }
    }

    func testOtherDashboardMenusFitTheirCreationActions() {
        for (mode, creation) in [("Automations", "Create Automation"), ("Knowledge", "New note")] {
            let app = launch(["-fixture-dashboard"])
            defer { app.terminate() }
            select(mode, in: app)
            let menu = app.buttons["dashboard.menu"]
            let frame = menu.frame
            menu.tap()
            let last = app.buttons[creation]
            XCTAssertTrue(last.waitForExistence(timeout: 3))
            XCTAssertTrue(last.isHittable, "Creation must not require scrolling the popup")
            XCTAssertLessThanOrEqual(last.frame.maxY, frame.maxY + 1)
        }
    }

    func testOtherDashboardHeadersAndSearch() {
        for (mode, title) in [("Automations", "Automations"), ("Knowledge", "Knowledge")] {
            let app = launch(["-fixture-dashboard", "-fixture-light", "-fixture-large-type"])
            defer { app.terminate() }
            select(mode, in: app)
            let heading = app.staticTexts[title].firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 3))
            XCTAssertGreaterThan(heading.frame.width, 0)
            XCTAssertLessThan(heading.frame.minX, 30)
            XCTAssertLessThanOrEqual(heading.frame.maxX, app.frame.maxX - 20)
            app.buttons["dashboard.menu"].tap()
            app.buttons["Search"].tap()
            XCTAssertTrue(app.buttons["Close search"].waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertTrue(app.textFields.firstMatch.exists)
            if mode == "Automations" {
                app.buttons["dashboard.menu"].tap()
                XCTAssertFalse(app.buttons["Choose agenda date"].exists)
            }
        }
    }

    private func select(_ mode: String, in app: XCUIApplication) {
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        if mode != "Sessions" { menu.tap(); app.buttons[mode].tap() }
        XCTAssertEqual(menu.value as? String, mode)
    }

    private func waitForFrame(_ element: XCUIElement, y: CGFloat, height: CGFloat) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                abs(element.frame.minY - y) <= 1 && abs(element.frame.height - height) <= 1
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 3), .completed, XCUIApplication().debugDescription)
    }

    private func waitForValue(_ text: String, in element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 3), .completed, element.debugDescription)
    }
}
