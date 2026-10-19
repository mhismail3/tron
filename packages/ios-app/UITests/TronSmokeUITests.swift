import CoreML
import UIKit
import Vision
import XCTest

final class TronSmokeUITests: XCTestCase {
    /// The task list names each task and its project; a finished task whose result the
    /// current Home has not admitted can be redelivered from its detail. Stop and steer
    /// live in the worker's own session (#911), so the detail has neither; the journey in
    /// TronHomeSheetsUITests opens that session.
    @MainActor
    func testHomeTaskListAndRedelivery() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-tasks")
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5))
        // A row names the task and its project; spend and unavailable copy never appear in a row.
        XCTAssertTrue(app.buttons["home-task-active"].label.contains("Settings model: continue epic #758"))
        XCTAssertTrue(app.buttons["home-task-active"].label.contains("tron"))
        XCTAssertFalse(app.staticTexts["Spend unavailable"].exists)
        keepScreenshot(named: "home-task-list")
        app.buttons["home-task-active"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-task-detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["home-task-spend"].label.contains("12 in · 480 cached · 3 out"),
                      "Fresh input stays apart from cache reads (#1250)")
        // Bring the Tokens row on screen so the capture shows the split it asserts.
        let spendRow = app.descendants(matching: .any)["home-task-spend"]
        for _ in 0..<4 where !spendRow.isHittable { app.swipeUp() }
        keepScreenshot(named: "home-task-detail-spend")
        XCTAssertFalse(app.staticTexts["Unpriced"].exists, "Task spend shows token counts only; the Gateway reports no cost")
        app.buttons["home-sheet-done-task"].tap()
        XCTAssertTrue(app.buttons["home-task-terminal"].waitForExistence(timeout: 5)); app.buttons["home-task-terminal"].tap()
        XCTAssertTrue(app.staticTexts["Finished · Final"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["home-task-redeliver"].firstMatch.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
        keepScreenshot(named: "home-task-redelivered")
    }

    @MainActor
    func testHomeTaskPermissionsRevokeDecideAndReconfirm() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-permissions-restored"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-settings")
        let reconfirm = app.buttons["home-permissions-reconfirm"]
        reveal(reconfirm, in: app); reconfirm.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
        revokeHomePermission(app, "Revoke scope scope-one")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:2", timeout: 5))
        revokeHomePermission(app, "Revoke grant grant-one")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:3", timeout: 5))
        for (id, count) in [("approve", 4), ("deny", 5)] {
            let decision = app.buttons["home-grant-\(id)-request-\(id)"]
            reveal(decision, in: app); decision.tap()
            XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:\(count)", timeout: 5))
            XCTAssertFalse(decision.exists, "Decided requests leave the pending projection")
        }
        keepScreenshot(named: "home-task-permission-denied")
    }

    /// Revoking is destructive: a cancelled confirmation changes nothing, and only the
    /// confirmed revoke reaches the Gateway.
    @MainActor
    func testHomePermissionRevokeRequiresConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-settings")
        reveal(app.buttons["Revoke scope scope-one"], in: app)
        app.buttons["Revoke scope scope-one"].tap()
        XCTAssertTrue(app.buttons["confirmation-cancel"].waitForExistence(timeout: 5))
        keepScreenshot(named: "home-permission-revoke-confirmation")
        app.buttons["confirmation-cancel"].tap()
        XCTAssertTrue(app.staticTexts["fixture.home-control-count"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["fixture.home-control-count"].label.contains("control-count:0"), "A cancelled revoke must not reach the Gateway")
        app.buttons["Revoke scope scope-one"].tap()
        confirmHomeAction(app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
    }

    /// A delayed socket response must not shrink the scroll viewport (and its
    /// edge material) to the loading row's intrinsic width, and the one shared
    /// sheet pulse stays centered in the visible sheet at medium and large detents
    /// and leaves chrome still when content arrives (#890). Exercise the real
    /// managed parent/child sheet stack, not a replica of its layout.
    @MainActor
    func testHomeSheetLoadingSurfaceRemainsFullWidth() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-presentation-loading"]
            if appearance == "dark" { app.launchArguments.append("-home-dark") }
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
            app.buttons["home-pinned-row"].tap()
            let ring = app.buttons["session-context-button"]
            XCTAssertTrue(waitForLabel(ring, containing: "Manage Home", timeout: 10))
            XCTAssertTrue(waitForEnabled(ring, timeout: 10))
            ring.tap()
            let done = app.buttons["home-sheet-done-manage"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            let mediumY = done.frame.midY
            XCTAssertGreaterThan(mediumY, app.windows.firstMatch.frame.height * 0.4)
            let manageMediumTop = assertHomeLoadingSurface(app, name: "\(appearance)-manage-medium", done: done)
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.descendants(matching: .any)["sheet-loading"].exists, "Arrived content retires the pulse")
            // Independent Manage Home reads travel together, not one round trip each.
            XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-sheet-read-peak"], containing: "sheet-read-peak:2", timeout: 2))
            XCTAssertEqual(done.frame.midY, mediumY, accuracy: 2, "Loading must not move sheet chrome")
            keepScreenshot(named: "sheet-\(appearance)-manage-loaded")
            tapManageRow(app, "home-manage-tasks")
            let taskDone = app.buttons["home-sheet-done-tasks"]
            XCTAssertTrue(taskDone.waitForExistence(timeout: 5))
            let tasksMediumTop = assertHomeLoadingSurface(app, name: "\(appearance)-tasks-medium", done: taskDone)
            let title = app.staticTexts["Tasks"].firstMatch
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                taskDone.frame.midY < mediumY - 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed)
            XCTAssertLessThan(assertHomeLoadingSurface(app, name: "\(appearance)-tasks-large", done: taskDone), tasksMediumTop - 100,
                              "The pulse re-centers in the larger visible sheet")
            let largeDoneY = taskDone.frame.midY
            XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 20))
            XCTAssertEqual(taskDone.frame.midY, largeDoneY, accuracy: 2, "Arriving content must not move sheet chrome")
            keepScreenshot(named: "sheet-\(appearance)-tasks-loaded-large")
            taskDone.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(ring.waitForExistence(timeout: 5))
            ring.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            XCTAssertEqual(assertHomeLoadingSurface(app, name: "\(appearance)-manage-reopened", done: done), manageMediumTop, accuracy: 2)
            app.staticTexts["Manage Home"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
            let manageExpanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                done.frame.midY < mediumY - 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [manageExpanded], timeout: 3), .completed)
            XCTAssertLessThan(assertHomeLoadingSurface(app, name: "\(appearance)-manage-large", done: done), manageMediumTop - 100,
                              "The pulse re-centers in the larger visible sheet")
            done.tap()
            XCTAssertTrue(ring.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testNestedHomeTasksErrorRetriesWithoutMovingChrome() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-tasks-error"]
            if appearance == "dark" { app.launchArguments.append("-home-dark") }
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
            app.buttons["home-pinned-row"].tap()
            openManageHome(app)
            tapManageRow(app, "home-manage-tasks")
            XCTAssertTrue(app.buttons["Reload"].waitForExistence(timeout: 5))
            let done = app.buttons["home-sheet-done-tasks"]
            let y = done.frame.midY
            keepScreenshot(named: "sheet-\(appearance)-tasks-error")
            assertManagedSheetSurface(app, title: "Tasks", name: "\(appearance)-tasks-error")
            app.buttons["Reload"].tap()
            XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5))
            XCTAssertEqual(done.frame.midY, y, accuracy: 2)
            keepScreenshot(named: "sheet-\(appearance)-tasks-retried")
            done.tap()
            XCTAssertTrue(app.buttons["home-sheet-done-manage"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    /// Asserts the one shared sheet pulse is exactly centered in the visible sheet
    /// and returns that sheet's top, so callers can prove a detent change moved it.
    @MainActor
    @discardableResult
    private func assertHomeLoadingSurface(_ app: XCUIApplication, name: String, done: XCUIElement) -> CGFloat {
        let loading = app.descendants(matching: .any)["sheet-loading"]
        let surface = app.descendants(matching: .any)["sheet-loading-surface"]
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        XCTAssertEqual(loading.label, "Loading Home…")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "sheet-loading").count, 1, "One pulse per sheet stack")
        XCTAssertFalse(app.staticTexts["Loading Home…"].exists, "Sheet loading never shows wrapping text")
        let window = app.windows.firstMatch.frame
        // The surface is the whole visible sheet: its full (inset, at the medium
        // detent) width, down to its bottom edge, and from its top above the toolbar.
        let sheet = surface.frame
        XCTAssertEqual(sheet.midX, window.midX, accuracy: 1, name)
        XCTAssertGreaterThan(sheet.width, window.width - 24, name)
        XCTAssertGreaterThan(sheet.maxY, window.maxY - 16, name)
        XCTAssertLessThanOrEqual(sheet.maxY, window.maxY, name)
        XCTAssertLessThan(sheet.minY, done.frame.minY, name)
        XCTAssertGreaterThan(sheet.minY, done.frame.midY - 60, name)
        XCTAssertEqual(loading.frame.midX, sheet.midX, accuracy: 1, "The pulse is centered in the visible sheet (\(name))")
        XCTAssertEqual(loading.frame.midY, sheet.midY, accuracy: 1, "The pulse is centered in the visible sheet (\(name))")
        keepScreenshot(named: "sheet-\(name)-loading")
        // The drawn pulse (not just its accessibility frame) sits there too, is
        // small (no label), and is drawn in the title's color. It fades in and its waves
        // breathe, so sample a few frames rather than trusting one instant.
        let probe = CGRect(x: sheet.midX - 80, y: sheet.midY - 80, width: 160, height: 160)
        var drawn: (center: CGPoint, extent: CGFloat)?
        for _ in 0..<5 where drawn == nil {
            drawn = accentCentroid(XCUIScreen.main.screenshot().image, in: probe, windowWidth: window.width)
            if drawn == nil { Thread.sleep(forTimeInterval: 0.15) }
        }
        guard let pulse = drawn else {
            XCTFail("No pulse drawn in the visible sheet (\(name))")
            return sheet.minY
        }
        XCTAssertEqual(pulse.center.x, sheet.midX, accuracy: 2, "The drawn pulse is centered (\(name))")
        XCTAssertEqual(pulse.center.y, sheet.midY, accuracy: 2, "The drawn pulse is centered (\(name))")
        XCTAssertLessThan(pulse.extent, 60, "The chat-opening pulse alone, no label (\(name))")
        assertManagedSheetSurface(app, title: app.staticTexts["Tasks"].exists ? "Tasks" : "Manage Home", name: name)
        return sheet.minY
    }

    /// Centroid and extent (points) of saturated pixels, the title-colored pulse, in `area`.
    private func accentCentroid(_ image: UIImage, in area: CGRect, windowWidth: CGFloat) -> (center: CGPoint, extent: CGFloat)? {
        guard let source = image.cgImage else { return nil }
        let scale = CGFloat(source.width) / windowWidth
        let width = Int(area.width), height = Int(area.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        guard let crop = source.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale,
                                                    width: area.width * scale, height: area.height * scale)) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sumX = 0.0, sumY = 0.0, count = 0.0, minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                // The pulse is the sheet title's color (green for Manage Home, its
                // row's teal for a sub-sheet): any saturated ink, never the gray material.
                guard max(r, g, b) - min(r, g, b) > 24 else { continue }
                // CGContext rows run bottom-up.
                let row = height - 1 - y
                sumX += Double(x); sumY += Double(row); count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard count > 20 else { return nil }
        return (CGPoint(x: area.minX + sumX / count + 0.5, y: area.minY + sumY / count + 0.5),
                CGFloat(max(maxX - minX, maxY - minY)))
    }

    @MainActor
    private func assertManagedSheetSurface(_ app: XCUIApplication, title: String, name: String) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
        XCTAssertEqual(done.allElementsBoundByIndex.filter(\.isHittable).count, 1,
                       "The active managed sheet owns one actionable dismissal control")
        let scroll = app.scrollViews.firstMatch
        XCTAssertGreaterThan(scroll.frame.width, app.windows.firstMatch.frame.width * 0.9,
                             "The sheet viewport and its edge material must not inherit the loading row's intrinsic width")
        // Accessibility reports the full ScrollView even when its overlay is
        // intrinsically narrow. Compare the actual material above the title,
        // away from text, controls and rounded corners; no device-specific golden.
        let title = app.staticTexts[title].firstMatch
        let screenshot = XCUIScreen.main.screenshot().image
        let y = title.frame.minY - 12
        let width = app.windows.firstMatch.frame.width
        let center = sheetPixel(screenshot, point: CGPoint(x: width * 0.5, y: y), windowWidth: width)
        for x in [0.25, 0.75] {
            let side = sheetPixel(screenshot, point: CGPoint(x: width * x, y: y), windowWidth: width)
            XCTAssertLessThan(zip(center, side).map { abs($0 - $1) }.max() ?? 1, 0.035,
                              "The edge material must cover the full sheet, not an opaque central column (\(name))")
        }
    }

    private func sheetPixel(_ image: UIImage, point: CGPoint, windowWidth: CGFloat) -> [Double] {
        guard let source = image.cgImage else { XCTFail("Missing screenshot pixels"); return [] }
        let scale = CGFloat(source.width) / windowWidth
        let area = CGRect(x: point.x * scale - 4, y: point.y * scale - 4, width: 9, height: 9)
        guard let crop = source.cropping(to: area) else { XCTFail("Missing material sample"); return [] }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel.prefix(3).map { Double($0) / 255 }
    }

    @MainActor
    func testHomeSheetsLoadingEmptyBlockedErrorAndReload() {
        continueAfterFailure = false
        for state in ["loading", "empty", "error", "blocked"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
            if state == "blocked" { app.launchArguments.append("-home-phase-blocked") } else { app.launchArguments.append("-home-browser-\(state)") }
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
            app.buttons["home-pinned-row"].tap()
            openManageHome(app)
            if state == "blocked" {
                // A memory problem is the status pill plus the Memory row's subtitle.
                XCTAssertTrue(waitForLabel(app.descendants(matching: .any)["home-manage-state"], containing: "Memory blocked", timeout: 5))
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "source-unavailable")).firstMatch.waitForExistence(timeout: 5))
                keepScreenshot(named: "home-sheet-blocked")
                app.terminate()
                continue
            }
            tapManageRow(app, "home-manage-memory-browser")
            if state == "loading" {
                XCTAssertTrue(app.descendants(matching: .any)["sheet-loading"].waitForExistence(timeout: 2))
                keepScreenshot(named: "home-memory-loading")
                XCTAssertTrue(app.descendants(matching: .any)["home-memory-row-39"].waitForExistence(timeout: 10))
            } else if state == "empty" {
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No memory yet")).firstMatch.waitForExistence(timeout: 5))
            } else {
                XCTAssertTrue(app.buttons["Reload"].waitForExistence(timeout: 5))
                keepScreenshot(named: "home-memory-error")
                app.buttons["Reload"].tap()
                XCTAssertTrue(app.descendants(matching: .any)["home-memory-row-39"].waitForExistence(timeout: 5))
            }
            keepScreenshot(named: "home-sheet-\(state)")
            app.terminate()
        }
        let empty = XCUIApplication()
        empty.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-context-empty"]
        empty.launch()
        defer { empty.terminate() }
        XCTAssertTrue(empty.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        empty.buttons["home-pinned-row"].tap()
        openManageHome(empty)
        // Before Home's first activation, Manage Home's context card has no activation line.
        XCTAssertTrue(empty.descendants(matching: .any)["home-context-breakdown"].waitForExistence(timeout: 5), empty.debugDescription)
        XCTAssertFalse(empty.descendants(matching: .any)["home-context-activation"].exists)
        keepScreenshot(named: "home-context-empty")
    }

    /// Manage Home's context card explains where the next request's context goes: one
    /// stacked bar of the window with a meaning per section, and no entry IDs or byte counts.
    @MainActor
    func testHomeContextShowsBreakdownWithoutRawIdentifiers() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        XCTAssertTrue(app.descendants(matching: .any)["home-context-breakdown"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["context-segmented-bar"].exists)
        for (id, label) in [("instructions", "Instructions"), ("profile", "About you"), ("memory", "Memory"),
                            ("chapter", "This chapter"), ("results", "Task results"), ("input", "Your message")] {
            XCTAssertTrue(app.descendants(matching: .any)["context-segment-\(id)"].label.hasPrefix(label), label)
        }
        // The header says how much is left, so the legend has no Free line (#963).
        XCTAssertFalse(app.descendants(matching: .any)["context-segment-free"].exists, "The legend has no Free line")
        XCTAssertTrue(app.descendants(matching: .any)["context-segment-memory"].label.contains("260 summaries"))
        XCTAssertFalse(app.staticTexts["activation-entry"].exists, "Context must not show an entry ID")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", " bytes")).firstMatch.exists, "Context must not show byte counts")
        keepScreenshot(named: "home-context-populated")
    }

    /// Opening a memory row shows its detail; its exact evidence opens from one standard row,
    /// and the next page continues to the older summaries.
    @MainActor
    func testHomeMemoryRowDetailOpensExactEvidence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-memory-browser")
        let row = app.descendants(matching: .any)["home-memory-row-39"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.label.contains("Task result: settings model epic #758 finished."))
        XCTAssertFalse(app.staticTexts["source-session · source-entry"].exists, "Memory rows show no raw evidence identifiers")
        keepScreenshot(named: "home-memory-rows")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-memory-detail"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Task result: settings model epic #758 finished."].exists)
        keepScreenshot(named: "home-memory-detail")
        tapManageRow(app, "home-memory-exact-evidence")
        XCTAssertTrue(app.descendants(matching: .any)["home-evidence-text"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Canonical original, not the memory projection"].exists)
        keepScreenshot(named: "home-exact-evidence")
        app.buttons["home-sheet-done-evidence"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-memory-detail"].waitForExistence(timeout: 5))
        app.buttons["home-sheet-done-memory-item"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // The oldest summary is on the next page of the newest-first view.
        XCTAssertFalse(app.descendants(matching: .any)["home-memory-summary-0-16"].exists)
        tapManageRow(app, "home-memory-older-top")
        XCTAssertTrue(app.descendants(matching: .any)["home-memory-summary-0-16"].waitForExistence(timeout: 5))
        keepScreenshot(named: "home-memory-next-page")
    }

    /// The sealed chapter opens its transcript; the active chapter, the current chat, does
    /// not. Browsing a chapter's memory filters the memory list to that chapter.
    @MainActor
    func testHomeChaptersSealedOpensTranscriptActiveBrowsesMemory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-chapters")
        XCTAssertTrue(app.buttons["home-chapter-2"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["home-chapter-1"].exists)
        keepScreenshot(named: "home-chapters-sheet")
        app.buttons["home-chapter-2"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-chapter-detail"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "user messages")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["home-chapter-open-transcript"].exists, "The active chapter is the current chat and has no transcript row")
        keepScreenshot(named: "home-chapter-active-detail")
        tapManageRow(app, "home-chapter-browse-memory")
        XCTAssertTrue(app.descendants(matching: .any)["home-memory-summary-32-2"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["home-memory-summary-28-4"].exists, "Browsing a chapter shows only that chapter's memory")
        keepScreenshot(named: "home-chapter-memory-filtered")
        app.buttons["home-sheet-done-memory"].tap()
        app.buttons["home-sheet-done-chapter"].tap()
        XCTAssertTrue(app.buttons["home-chapter-1"].waitForExistence(timeout: 5))
        app.buttons["home-chapter-1"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-chapter-detail"].waitForExistence(timeout: 5), app.debugDescription)
        tapManageRow(app, "home-chapter-open-transcript")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-opened-session"], containing: "opened-session:home-chapter-sealed", timeout: 10))
        XCTAssertTrue(waitForLabel(app.buttons["session-context-button"], containing: "Manage Session", timeout: 10), "A read-only chapter chat must not claim Home")
        keepScreenshot(named: "home-chapter-read-only")
    }

    /// Capture the standard rows and conditional exceptions without mutating grants.
    @MainActor
    func testHomeDelegationSettingsApprovalCaptures() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            for state in ["pending", "empty", "restored"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
                if state != "pending" { app.launchArguments.append("-home-permissions-\(state)") }
                if appearance == "dark" { app.launchArguments.append("-home-dark") }
                app.launch()
                XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
                app.buttons["home-pinned-row"].tap()
                openManageHome(app)
                tapManageRow(app, "home-manage-settings")
                let anchor = state == "pending" ? app.buttons["home-grant-approve-request-approve"]
                    : state == "restored" ? app.buttons["home-permissions-reconfirm"] : app.buttons["Revoke scope scope-one"]
                reveal(anchor, in: app)
                XCTAssertTrue(anchor.isHittable, app.debugDescription)
                if state == "empty" { app.swipeUp() }
                keepScreenshot(named: "approval-delegation-\(state)-\(appearance)")
                if state == "pending" {
                    for component in ["date", "time"] {
                        // The combined settings row can also project the action's
                        // identifier; the last match is the actual trailing button.
                        let matches = app.buttons.matching(identifier: "home-grant-expiry-\(component)-request-approve")
                        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                        let expiry = matches.element(boundBy: matches.count - 1)
                        XCTAssertTrue(expiry.isHittable, app.debugDescription)
                        expiry.tap()
                        let title = "Expiry \(component)"
                        XCTAssertTrue(app.navigationBars.staticTexts[title].firstMatch.waitForExistence(timeout: 5), "Home must open the same managed picker sheet as Automations, not a native compact popover: \(app.debugDescription)")
                        keepScreenshot(named: "approval-delegation-expiry-\(component)-\(appearance)")
                        app.buttons["Done"].firstMatch.tap()
                    }
                }
                XCTAssertFalse(app.buttons["home-permissions-reload"].exists)
                XCTAssertEqual(app.buttons["home-permissions-reconfirm"].exists, state == "restored")
                if state == "empty" {
                    XCTAssertFalse(app.staticTexts["Pending requests"].exists)
                    XCTAssertFalse(app.staticTexts["One-use grants"].exists)
                }
                app.terminate()
            }
        }
    }

    /// Compact destructive capsule review, without accepting a revocation.
    @MainActor
    func testCaptureHomeRevokeCapsuleForReview() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for large in [false, true] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-permissions-empty"]
                if mode == "dark" { app.launchArguments.append("-home-dark") }
                if large {
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                }
                app.launch()
                XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 15))
                app.buttons["home-pinned-row"].tap()
                openManageHome(app)
                tapManageRow(app, "home-manage-settings")
                let revoke = app.buttons["Revoke scope scope-one"]
                reveal(revoke, in: app)
                XCTAssertTrue(revoke.isHittable, app.debugDescription)
                keepScreenshot(named: "1318-delegation-\(mode)-\(large ? "accessibility" : "standard")")
                app.terminate()
            }
        }
    }

    /// Capture-only review of the production surfaces. Readiness/navigation here
    /// is not behavioral acceptance of edits, reset, provenance, or prompt menus.
    @MainActor
    func testCaptureCompactSettingsAndFadeInLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let dark = appearance == "dark"
            for surface in ["prompt", "changes", "home", "session", "global", "photo"] {
                let app = XCUIApplication()
                switch surface {
                case "prompt":
                    app.launchArguments = ["-tron-tool-sheets-polish-fixture", "-polish-scenario", "prompt", dark ? "-polish-dark" : "-polish-light"]
                case "photo":
                    app.launchArguments = ["-tron-chat-display-fixture", "-chat-display-inline-group", dark ? "-polish-dark" : "-polish-light"]
                case "home":
                    app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
                    if dark { app.launchArguments.append("-home-dark") }
                case "session":
                    app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", appearance]
                default:
                    app.launchArguments = ["-tron-settings-renderer-fixture"]
                    if surface == "changes" { app.launchArguments += ["-settings-changes", "-settings-changes-session", "-settings-changes-scope"] }
                    if dark { app.launchArguments.append("-settings-renderer-dark") }
                }
                app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                app.launch()
                defer { app.terminate() }
                switch surface {
                case "prompt":
                    XCTAssertTrue(app.staticTexts["Transcript presentation review"].waitForExistence(timeout: 10))
                case "photo":
                    let preview = app.buttons["Open Home dashboard after the fix photo preview"]
                    XCTAssertTrue(preview.waitForExistence(timeout: 25), app.debugDescription)
                    preview.tap()
                    XCTAssertTrue(app.buttons["Technical details"].waitForExistence(timeout: 10))
                case "home":
                    XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
                    app.buttons["home-pinned-row"].tap()
                    openManageHome(app)
                    tapManageRow(app, "home-manage-settings")
                    expandSettingsSheet(app, title: "Home Settings")
                    XCTAssertTrue(app.buttons["Model"].firstMatch.waitForExistence(timeout: 5))
                case "session":
                    XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
                    app.buttons["Stop session"].tap()
                    app.buttons["Release terminal settlement"].tap()
                    openChatSettings(app)
                    expandSettingsSheet(app, title: "Session Settings")
                case "changes":
                    XCTAssertTrue(app.buttons["settings-change-ui-change"].waitForExistence(timeout: 10))
                    app.buttons["All scopes"].tap()
                    XCTAssertTrue(app.buttons["settings-change-project-change"].waitForExistence(timeout: 5))
                default:
                    let model = app.buttons["settings-section-model-open"]
                    XCTAssertTrue(model.waitForExistence(timeout: 10))
                    model.tap()
                    XCTAssertTrue(app.navigationBars.staticTexts["Model"].waitForExistence(timeout: 5))
                    expandSettingsSheet(app, title: "Model")
                }
                keepScreenshot(named: "1308-\(surface)-\(appearance)")
                app.terminate()
            }
        }
    }

    /// Approval-only captures of the reported Compaction mix and the shared
    /// value/Revert/Unset labels. Mutation/geometry acceptance runs after review.
    @MainActor
    func testCaptureSettingsTrailingAlignmentForReview() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            for textSize in ["standard", "accessibility"] {
                for surface in ["compaction", "controls"] {
                    let app = XCUIApplication()
                    app.launchArguments = ["-tron-settings-renderer-fixture",
                        surface == "compaction" ? "-settings-alignment-review" : "-settings-controls-review",
                        "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                    if appearance == "dark" { app.launchArguments.append("-settings-renderer-dark") }
                    if textSize == "accessibility" {
                        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
                    }
                    app.launch()
                    XCTAssertTrue(app.staticTexts[surface == "compaction" ? "Automatic compaction" : "Inherited value"].firstMatch.waitForExistence(timeout: 10))
                    keepScreenshot(named: "1321-\(surface)-\(appearance)-\(textSize)")
                    if textSize == "accessibility" {
                        app.scrollViews.firstMatch.swipeUp()
                        keepScreenshot(named: "1321-\(surface)-\(appearance)-\(textSize)-lower")
                    }
                    app.terminate()
                }
            }
        }
    }

    /// Measure the rendered glass, independently of the transparent AX target.
    /// This fails on the old centered-circle layout even though its AX edges agree.
    @MainActor
    func testSettingsPaintedEdgesSpacingAndHitTargets() {
        for appearance in ["light", "dark"] {
            for largeText in [false, true] {
                for gallery in [false, true] {
                    let app = XCUIApplication()
                    app.launchArguments = ["-tron-settings-renderer-fixture", gallery ? "-settings-controls-review" : "-settings-alignment-review"]
                    if appearance == "dark" { app.launchArguments.append("-settings-renderer-dark") }
                    if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
                    app.launch()
                    let row: (String) -> XCUIElement = { app.descendants(matching: .any)["settings-row-\($0)"] }
                    // A non-inspectable row combines AX metadata into a parent
                    // button too. Select the real labeled child, never that row.
                    let button: (String, String) -> XCUIElement = { id, label in
                        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", id, label)).firstMatch
                    }
                    let inherited = gallery ? button("alignment.inherited", "16,384 tokens") : settingEditor(row("context.branchSummary.reserveTokens"))
                    let short = gallery ? button("alignment.short", "—") : app.buttons["settings-row-context.compaction.enabled-reset"]
                    let pairs = gallery
                        ? [(button("alignment.revert-value", "High"), button("alignment.revert", "Revert")),
                           (button("alignment.unset-value", "16,384 tokens"), button("alignment.unset", "Unset"))]
                        : [(settingEditor(row("context.compaction.reserveTokens")), app.buttons["settings-row-context.compaction.reserveTokens-reset"]),
                           (settingEditor(row("model.thinking_role_summarizer_")), app.buttons["settings-row-model.thinking_role_summarizer_-reset"])]
                    var measurements = [String]()
                    func measure(_ target: XCUIElement, circle: Bool = false) -> CGRect {
                        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
                        let scroll = app.scrollViews.firstMatch
                        let viewport = scroll.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: 0, dy: 50)
                        for _ in 0..<10 where !viewport.contains(target.frame) {
                            if target.frame.minY < viewport.minY { scroll.swipeDown() } else { scroll.swipeUp() }
                        }
                        XCTAssertTrue(viewport.contains(target.frame), "Measure the entire visible target: \(target.frame)")
                        let hit = target.frame
                        // AX can serialize 44 as 43.999999999999986.
                        XCTAssertGreaterThanOrEqual(hit.width + 0.001, 44)
                        XCTAssertGreaterThanOrEqual(hit.height + 0.001, 44)
                        let visible = paintedSettingsControl(target, in: app)
                        if circle {
                            XCTAssertEqual(hit.width, hit.height, accuracy: 0.5)
                            XCTAssertEqual(visible.width, 28, accuracy: 1.5, "Round glass diameter, not the hit frame")
                            XCTAssertEqual(visible.height, 28, accuracy: 1.5)
                        }
                        measurements.append("\(target.identifier): hit=\(hit), painted=\(visible)")
                        return visible
                    }
                    let right = measure(inherited).maxX
                    // Native renderer groups use the standard 20pt sheet + 14pt row inset.
                    XCTAssertEqual(right, app.windows.firstMatch.frame.maxX - 34, accuracy: 1)
                    XCTAssertEqual(measure(short, circle: !gallery).maxX, right, accuracy: 1)
                    for (value, circle) in pairs {
                        let valuePaint = measure(value)
                        let circlePaint = measure(circle, circle: true)
                        XCTAssertEqual(circlePaint.maxX, right, accuracy: 1, "Painted trailing edges must match the standalone value")
                        XCTAssertEqual(circlePaint.minX - valuePaint.maxX, 16, accuracy: 1, "Visible spacing must not depend on glyph or value width")
                        XCTAssertLessThanOrEqual(value.frame.maxX, circle.frame.minX + 0.5, "Independent targets must not overlap")
                    }
                    let name = "1321-measured-\(gallery ? "gallery" : "compaction")-\(appearance)-\(largeText ? "large" : "standard")"
                    let attachment = XCTAttachment(string: measurements.joined(separator: "\n"))
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    keepScreenshot(named: name)
                    app.terminate()
                }
            }
        }
    }

    /// Center-line extents of actual glass pixels against adjacent row material.
    /// No production geometry hook or inferred inset from the 44pt frame: raster
    /// sampling detects a centered 28pt circle ending 8pt before the target edge.
    @MainActor
    private func paintedSettingsControl(_ target: XCUIElement, in app: XCUIApplication) -> CGRect {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { XCTFail("Missing pixels"); return .zero }
        let frame = target.frame
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        func strip(_ rect: CGRect) -> [[Int]] {
            // AX coordinates can be fractional pixels. CGImage expands fractional
            // crops; round explicitly so a one-pixel scanline stays one pixel.
            let pixels = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                                width: rect.width.rounded(), height: rect.height.rounded())
            guard let crop = image.cropping(to: pixels) else { XCTFail("Missing control raster: \(rect)"); return [] }
            var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let context = CGContext(data: &bytes, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                    bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            var samples = [[Int]]()
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                samples.append([Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])])
            }
            return samples
        }
        let background = strip(CGRect(x: (frame.maxX + 6) * scale, y: frame.midY * scale, width: 1, height: 1)).first ?? []
        func extent(_ rect: CGRect, reversed: Bool = false) -> ClosedRange<CGFloat> {
            let samples = strip(rect)
            let ink = samples.indices.filter { index in
                let differences = zip(samples[index], background).map { abs($0.0 - $0.1) }
                return (differences.max() ?? 0) > 4
            }
            guard let first = ink.first, let last = ink.last else { XCTFail("No visible control surface: \(target.label)"); return 0...0 }
            let start = reversed ? samples.count - 1 - last : first
            let end = reversed ? samples.count - first : last + 1
            return CGFloat(start) / scale...CGFloat(end) / scale
        }
        let horizontal = extent(CGRect(x: frame.minX * scale, y: frame.midY * scale, width: frame.width * scale, height: 1))
        let centerX = frame.minX + (horizontal.lowerBound + horizontal.upperBound) / 2
        // CGContext's one-column buffer is bottom-up; restore screen coordinates.
        let vertical = extent(CGRect(x: centerX * scale, y: frame.minY * scale, width: 1, height: frame.height * scale), reversed: true)
        return CGRect(x: frame.minX + horizontal.lowerBound, y: frame.minY + vertical.lowerBound,
                      width: horizontal.upperBound - horizontal.lowerBound, height: vertical.upperBound - vertical.lowerBound)
    }

    /// Capture-only navigation for the Accounts → Providers grouping. Count and
    /// Refresh are rendered from the real catalog owner over a synthetic socket.
    @MainActor
    func testCaptureGlobalAccountsAndProviderModelsInLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if appearance == "dark" { app.launchArguments.append("-settings-renderer-dark") }
            app.launch()
            defer { app.terminate() }
            let providers = app.buttons["settings-link-Model Providers"]
            XCTAssertTrue(providers.waitForExistence(timeout: 10))
            keepScreenshot(named: "1308-global-accounts-\(appearance)")
            providers.tap()
            expandSettingsSheet(app, title: "Providers")
            XCTAssertTrue(app.staticTexts["3 models currently available"].waitForExistence(timeout: 10))
            keepScreenshot(named: "1308-providers-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testProviderModelRoutesAndRefreshAreIndependent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-provider-actions"]
        app.launch(); defer { app.terminate() }
        let operations = app.staticTexts["fixture.provider-operations"]
        XCTAssertTrue(app.buttons["settings-link-Model Providers"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings-link-Custom Models"].exists)
        app.buttons["settings-link-Model Providers"].tap()
        expandSettingsSheet(app, title: "Providers")
        XCTAssertTrue(app.staticTexts["3 models currently available"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(operations, containing: "refresh:0 custom-read:0 custom-write:0 credentials:0", timeout: 5))
        app.buttons["Refresh"].tap()
        XCTAssertTrue(waitForLabel(operations, containing: "refresh:1 custom-read:0 custom-write:0 credentials:0", timeout: 5),
                      "Refresh must dispatch only the owned global catalog command")
        XCTAssertFalse(app.navigationBars.staticTexts["Custom Models"].exists, "Refresh must not navigate to the editor")
        app.buttons["settings-link-Custom Models"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Custom Models"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Provider"].waitForExistence(timeout: 5), "The existing guided editor must be usable")
        XCTAssertTrue(waitForLabel(operations, containing: "refresh:1 custom-read:1 custom-write:0 credentials:0", timeout: 5))
        keepScreenshot(named: "1308-custom-models-editor")
        closeTopSheet(app)
        XCTAssertTrue(app.navigationBars.staticTexts["Providers"].waitForExistence(timeout: 5))
        app.buttons["Details for Fixture Provider"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Fixture Provider"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(operations, containing: "refresh:1 custom-read:1 custom-write:0 credentials:0", timeout: 5),
                      "Provider setup navigation must neither refresh the catalog nor edit custom definitions/credentials")
        closeTopSheet(app)
        XCTAssertTrue(app.navigationBars.staticTexts["Providers"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "settings-link-Custom Models").count, 1)
    }

    @MainActor
    func testSettingsRowInspectionAndActionsStayIndependent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-renderer-source-actions"]
        app.launch(); defer { app.terminate() }
        let applied = app.staticTexts["fixture.settings-renderer-applied"]
        openRendererSection(app, "model")
        // Medium sheets scale the entire native AX projection (386/402 here).
        // Measure logical target sizes at large; the other journeys operate at medium.
        expandSettingsSheet(app, title: "Model")
        let row = app.descendants(matching: .any)["settings-row-model.ref"]
        let source = app.buttons["settings-row-model.ref-source"]
        let editor = settingEditor(row)
        let reset = app.buttons["settings-row-model.ref-reset"]
        for target in [source, editor, reset] {
            // Sheet presentation briefly scales the underlying AX geometry.
            // Wait for the target's actual admitted 44-point frame, not a sleep.
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in target.isHittable && target.frame.height >= 44 && target.frame.width >= 44 },
                object: target)], timeout: 5), .completed, "\(target.label): \(target.frame)")
        }
        XCTAssertFalse(source.frame.intersects(editor.frame), "Inspection and editing must not share targets")
        XCTAssertFalse(source.frame.intersects(reset.frame), "Inspection and mutation must not share targets")
        XCTAssertFalse(editor.frame.intersects(reset.frame), "Editing and Revert must not share targets")
        source.tap()
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForExistence(timeout: 5))
        XCTAssertTrue(showsText("Future source", in: app))
        XCTAssertEqual(applied.label, "applied:0", "Row inspection cannot mutate or reset")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Lite")).firstMatch.exists)
        closeTopSheet(app)
        editor.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Lite")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Value & Source"].exists, "Edit cannot also activate inspection")
        closeTopSheet(app)
        XCTAssertEqual(applied.label, "applied:0", "Opening/dismissing an editor cannot submit its draft")
        // The leading strip is invisible hit area after painted-edge alignment.
        // It must still invoke Revert, not the adjacent value editor or row body.
        reset.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        XCTAssertTrue(waitForLabel(applied, containing: "applied:1", timeout: 5))
        XCTAssertEqual(editor.value as? String, "Fixture Lite")
        XCTAssertFalse(app.staticTexts["Value & Source"].exists, "Revert cannot also activate inspection")
        closeTopSheet(app)
        openRendererSection(app, "context")
        let toggleRow = app.descendants(matching: .any)["settings-row-context.images.block"]
        let toggle = toggleRow.switches.firstMatch
        let before = toggle.value as? String
        app.buttons["settings-row-context.images.block-source"].tap()
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForExistence(timeout: 5))
        XCTAssertEqual(applied.label, "applied:1")
        closeTopSheet(app)
        XCTAssertEqual(toggle.value as? String, before, "Inspecting a toggle row cannot toggle it")
        toggle.tap()
        XCTAssertTrue(waitForLabel(applied, containing: "applied:2", timeout: 5))
        XCTAssertNotEqual(toggle.value as? String, before)
        XCTAssertFalse(app.staticTexts["Value & Source"].exists)
        keepScreenshot(named: "1308-independent-row-actions")
    }

    /// Show the one provenance destination after source/qualifier pills have
    /// been removed. This is capture navigation only; action isolation is a
    /// separate post-approval behavioral journey.
    @MainActor
    func testCaptureValueAndSourceInLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", appearance,
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
            app.buttons["Stop session"].tap()
            app.buttons["Release terminal settlement"].tap()
            openChatSettings(app)
            expandSettingsSheet(app, title: "Session Settings")
            let body = app.buttons["settings-row-model.thinking_role_chat_-source"]
            XCTAssertTrue(body.waitForExistence(timeout: 5))
            body.tap()
            expandSettingsSheet(app, title: "Value & Source")
            keepScreenshot(named: "1308-value-source-\(appearance)")
            app.terminate()
        }
    }

    /// Measure the rendered shared-row glyph, not its fixed AX/layout frame:
    /// an oversized SF Symbol can paint outside that frame at accessibility sizes.
    @MainActor
    func testSharedSettingsGlyphStaysInsideColumn() {
        for mode in ["light", "dark"] {
            var standardTitleHeight: CGFloat = 0
            for large in [false, true] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review"]
                if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
                if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
                app.launch()
                defer { app.terminate() }
                XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
                app.buttons["Open Settings"].tap()
                expandSettingsSheet(app, title: "Global Settings")
                let row = app.buttons["settings-link-Appearance"].firstMatch
                let title = app.staticTexts["Appearance"].firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                XCTAssertTrue(row.isHittable)
                XCTAssertGreaterThanOrEqual(row.frame.height, 44)
                // Native sheet presentation can scale the entire content at
                // XXXL. Normalize its 20pt sheet insets, not the glyph's layout
                // frame (which cannot reveal ink overflowing that frame).
                let presentationScale = row.frame.width / (app.windows.firstMatch.frame.width - 40)
                if large {
                    XCTAssertGreaterThan(title.frame.height / presentationScale, standardTitleHeight * 2,
                                         "Only the decorative glyph is capped; meaningful text must still grow at XXXL")
                } else {
                    standardTitleHeight = title.frame.height / presentationScale
                }
                XCTAssertEqual(title.frame.minX - row.frame.minX, 48 * presentationScale, accuracy: 0.5,
                               "Keep the shared 14pt inset, 22pt icon column and 12pt gap")
                let glyph = paintedSettingsGlyph(row: row.frame, label: title.frame, in: app)
                let suffix = "\(mode)-\(large ? "large" : "standard")"
                let evidence = XCTAttachment(string: "row=\(row.frame)\ntitle=\(title.frame)\npainted glyph=\(glyph)")
                evidence.name = "1325-glyph-metrics-\(suffix)"
                evidence.lifetime = .keepAlways
                add(evidence)
                keepScreenshot(named: "1325-glyph-global-\(suffix)")
                XCTAssertGreaterThan(glyph.width, 5, "Require real colored symbol pixels; an absent/hidden glyph cannot pass")
                XCTAssertLessThanOrEqual(glyph.width, 22 * presentationScale + 1, "Decorative glyph must fit its 22pt column, with 1pt raster tolerance")
                XCTAssertLessThanOrEqual(glyph.height, 22 * presentationScale + 1)
                XCTAssertGreaterThanOrEqual(glyph.minX, row.frame.minX + 14 * presentationScale - 1)
                XCTAssertLessThanOrEqual(glyph.maxX, title.frame.minX - 12 * presentationScale + 1,
                                         "Preserve the shared 12pt icon-to-label gap")
                row.tap()
                XCTAssertTrue(app.staticTexts["Color Mode"].waitForExistence(timeout: 5),
                              "The unchanged row target still opens Appearance")
            }
        }
    }

    /// Color-select the actual emerald symbol against neutral text and the
    /// low-saturation card material. No app geometry hook or glyph AX exposure.
    @MainActor
    private func paintedSettingsGlyph(row: CGRect, label: CGRect, in app: XCUIApplication) -> CGRect {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { XCTFail("Missing screenshot"); return .zero }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let region = CGRect(x: (row.minX * scale).rounded(), y: (row.minY * scale).rounded(),
                            width: ((label.minX - row.minX) * scale).rounded(), height: (row.height * scale).rounded())
        guard let crop = image.cropping(to: region) else { XCTFail("Missing leading-column raster"); return .zero }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &bytes, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var minX = crop.width, minY = crop.height, maxX = -1, maxY = -1
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let offset = (y * crop.width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                if g > r + 100 && g > b + 15 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX else { XCTFail("No emerald glyph ink"); return .zero }
        // CGContext rows are bottom-up; map back into native screen points.
        return CGRect(x: (region.minX + CGFloat(minX)) / scale,
                      y: (region.minY + CGFloat(crop.height - 1 - maxY)) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Expanded route preview only; durable policy/receipt acceptance waits for approval.
    @MainActor
    func testExpandedSettingsRoutesForVisualReview() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            for large in [false, true] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review"]
                if mode == "dark" { app.launchArguments.append("-settings-renderer-dark") }
                if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
                app.launch()
                XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
                app.buttons["Open Settings"].tap()
                expandSettingsSheet(app, title: "Global Settings")
                let suffix = "\(mode)-\(large ? "large" : "standard")"
                keepScreenshot(named: "1325-expanded-global-\(suffix)")
                tapScrolling(app.buttons["settings-link-App Customizations"], in: app)
                expandSettingsSheet(app, title: "App Customizations")
                keepScreenshot(named: "1325-expanded-customizations-\(suffix)")
                if !large {
                    // The combined row inherits its child's button trait but its
                    // center is a label. Tap the actual trailing value control.
                    app.buttons["Dashboard View"].firstMatch.buttons["Dashboard View"].firstMatch.tap()
                    XCTAssertTrue(app.buttons["settings-option-By Project / Server"].waitForExistence(timeout: 5))
                    keepScreenshot(named: "1325-expanded-dashboard-view-\(suffix)")
                    closeTopSheet(app)
                    tapScrolling(app.buttons["Visible Servers"].firstMatch.buttons["Visible Servers"].firstMatch, in: app)
                    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Workshop Mac")).firstMatch.waitForExistence(timeout: 5))
                    keepScreenshot(named: "1325-expanded-visible-servers-\(suffix)")
                    closeTopSheet(app)
                }
                closeTopSheet(app)
                tapScrolling(app.buttons["settings-section-model-open"], in: app)
                expandSettingsSheet(app, title: "Models")
                keepScreenshot(named: "1325-expanded-models-\(suffix)")
                closeTopSheet(app)
                if !large {
                    tapScrolling(app.buttons["settings-section-advanced-open"], in: app)
                    expandSettingsSheet(app, title: "More Settings")
                    keepScreenshot(named: "1325-expanded-more-\(suffix)")
                    closeTopSheet(app)
                    tapScrolling(app.buttons["settings-link-Setup & Experiments"], in: app)
                    expandSettingsSheet(app, title: "Setup & Experiments")
                    XCTAssertTrue(app.switches["Run Swift files"].waitForExistence(timeout: 5))
                    keepScreenshot(named: "1325-expanded-setup-\(suffix)")
                    closeTopSheet(app)
                    keepScreenshot(named: "1325-expanded-diagnostics-\(suffix)")
                }
                app.terminate()
            }
            let home = XCUIApplication()
            home.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
            if mode == "dark" { home.launchArguments.append("-home-dark") }
            home.launch()
            XCTAssertTrue(home.buttons["dashboard.menu"].waitForExistence(timeout: 10))
            home.buttons["dashboard.menu"].tap()
            XCTAssertTrue(home.buttons["New Session"].waitForExistence(timeout: 5))
            keepScreenshot(named: "1325-expanded-tron-menu-\(mode)")
            home.terminate()
            home.launch()
            XCTAssertTrue(home.buttons["home-pinned-row"].waitForExistence(timeout: 10))
            home.buttons["home-pinned-row"].tap()
            openManageHome(home)
            tapManageRow(home, "home-manage-settings")
            expandSettingsSheet(home, title: "Home Settings")
            keepScreenshot(named: "1325-expanded-home-settings-\(mode)")
            tapScrolling(home.buttons["settings-section-model-open"], in: home)
            expandSettingsSheet(home, title: "Models")
            keepScreenshot(named: "1325-expanded-home-models-\(mode)")
            let scopes = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Revoke")).firstMatch
            reveal(scopes, in: home)
            XCTAssertTrue(scopes.isHittable, home.debugDescription)
            keepScreenshot(named: "1325-expanded-home-delegation-\(mode)")
            home.terminate()
        }
    }

    /// Visual approval journey over production surfaces with explicit synthetic
    /// wire values. This is navigation/rendering proof, not real-Gateway policy proof.
    @MainActor
    func testSettingsScopeVisualReviewInLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            for scope in ["global", "changes", "home", "session", "project"] {
                let app = XCUIApplication()
                if scope == "home" {
                    app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
                    if appearance == "dark" { app.launchArguments.append("-home-dark") }
                } else if scope == "session" {
                    app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", appearance]
                } else if scope == "project" {
                    app.launchArguments = ["-tron-new-session-fixture", "-new-session-scenario", "project-settings", "-fixture-appearance", appearance]
                } else {
                    app.launchArguments = ["-tron-settings-renderer-fixture"]
                    if scope == "changes" { app.launchArguments += ["-settings-changes", "-settings-changes-session", "-settings-changes-scope"] }
                    if appearance == "dark" { app.launchArguments.append("-settings-renderer-dark") }
                }
                app.launch()
                defer { app.terminate() }
                if scope == "home" {
                    XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
                    app.buttons["home-pinned-row"].tap()
                    openManageHome(app)
                    tapManageRow(app, "home-manage-settings")
                    expandSettingsSheet(app, title: "Home Settings")
                    XCTAssertTrue(app.buttons["settings-section-model-open"].waitForExistence(timeout: 5))
                    keepScreenshot(named: "1325-home-\(appearance)")
                    captureSettingsTools(app, scope: scope, appearance: appearance)
                    captureConfiguration(app, scope: scope, appearance: appearance)
                } else if scope == "session" {
                    XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
                    app.buttons["Stop session"].tap()
                    app.buttons["Release terminal settlement"].tap()
                    expandSettingsSheet(app, title: "Manage Session")
                    let models = app.descendants(matching: .any)["session-model-summary"]
                    XCTAssertTrue(models.buttons["settings-row-model.thinking_role_chat_-source"].waitForExistence(timeout: 5))
                    keepScreenshot(named: "1325-session-\(appearance)-canonical-models")
                    tapScrolling(app.buttons["Available Tools"], in: app)
                    expandSettingsSheet(app, title: "Available Tools")
                    XCTAssertTrue(app.switches["Read File"].waitForExistence(timeout: 5), app.debugDescription)
                    keepScreenshot(named: "1325-session-\(appearance)-canonical-tools")
                    closeTopSheet(app)
                    openChatSettings(app)
                    expandSettingsSheet(app, title: "Session Settings")
                    keepScreenshot(named: "1325-session-\(appearance)")
                    captureConfiguration(app, scope: scope, appearance: appearance)
                    captureSettingsTools(app, scope: scope, appearance: appearance)
                    let source = app.descendants(matching: .any)["settings-configuration"].buttons["settings-row-model.thinking_role_chat_-source"]
                    for _ in 0..<12 where !source.isHittable { app.swipeDown() }
                    source.tap()
                    XCTAssertTrue(app.navigationBars.staticTexts["Value & Source"].waitForExistence(timeout: 5))
                    keepScreenshot(named: "1325-session-\(appearance)-source")
                    closeTopSheet(app)
                } else if scope == "project" {
                    XCTAssertTrue(app.buttons["project-settings-link"].waitForExistence(timeout: 10))
                    app.buttons["project-settings-link"].tap()
                    expandSettingsSheet(app, title: "Project Settings")
                    keepScreenshot(named: "1325-project-\(appearance)")
                    captureSettingsTools(app, scope: scope, appearance: appearance)
                } else if scope == "changes" {
                    XCTAssertTrue(app.buttons["settings-changes-filters"].waitForExistence(timeout: 10))
                    XCTAssertTrue(app.staticTexts["All scopes"].firstMatch.exists || app.buttons["All scopes"].exists)
                    XCTAssertTrue(app.buttons["settings-change-ui-change"].waitForExistence(timeout: 5))
                    keepScreenshot(named: "1305-changes-\(appearance)")
                    app.buttons["All scopes"].tap()
                    let project = app.buttons["settings-change-project-change"]
                    XCTAssertTrue(project.waitForExistence(timeout: 5))
                    keepScreenshot(named: "1305-changes-\(appearance)-all-scopes")
                    project.tap()
                    let readOnly = app.staticTexts["Repository configuration is read-only"]
                    reveal(readOnly, in: app)
                    XCTAssertTrue(readOnly.isHittable, app.debugDescription)
                    XCTAssertFalse(app.buttons["Undo"].exists)
                    XCTAssertFalse(app.buttons["Apply again"].exists)
                    keepScreenshot(named: "1305-changes-\(appearance)-repository-detail")
                } else {
                    XCTAssertTrue(app.buttons["settings-section-model-open"].waitForExistence(timeout: 10))
                    keepScreenshot(named: "1305-global-\(appearance)")
                }
                app.terminate()
            }
        }
    }

    @MainActor
    private func captureSettingsTools(_ app: XCUIApplication, scope: String, appearance: String) {
        let container = scope == "session" ? app.descendants(matching: .any)["settings-configuration"] : app
        let row = container.descendants(matching: .any)["settings-row-tools.active"]
        let editor = settingEditor(row)
        reveal(editor, in: app)
        XCTAssertTrue(editor.isHittable, app.debugDescription)
        keepScreenshot(named: "1325-\(scope)-\(appearance)-direct-tools")
        editor.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Tools"].waitForExistence(timeout: 5))
        expandSettingsSheet(app, title: "Tools")
        let tool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", scope == "home" ? "Ask User" : "Read File")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "1325-\(scope)-\(appearance)-populated-tools")
        closeTopSheet(app)
    }

    @MainActor
    private func captureConfiguration(_ app: XCUIApplication, scope: String, appearance: String) {
        let configuration = app.buttons["Configuration"]
        reveal(configuration, in: app)
        configuration.tap()
        expandSettingsSheet(app, title: "Configuration")
        XCTAssertTrue(app.descendants(matching: .any)["settings-row-model.ref_role_chat_"].waitForExistence(timeout: 5))
        keepScreenshot(named: "1325-\(scope)-\(appearance)-configuration")
        let source = app.descendants(matching: .any)["settings-configuration"].buttons["settings-row-tools.active-source"]
        reveal(source, in: app)
        XCTAssertTrue(source.isHittable, app.debugDescription)
        keepScreenshot(named: "1325-\(scope)-\(appearance)-configuration-tools")
    }

    /// Measure the actual shared Revert button, not its enclosing settings row.
    @MainActor
    private func assertCircularRevert(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let frame = button.frame
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertEqual(frame.width, frame.height, accuracy: 0.5,
                       "Revert must keep a square target around its circular glass: \(frame)", file: file, line: line)
    }

    @MainActor
    private func expandSettingsSheet(_ app: XCUIApplication, title: String) {
        let heading = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
    }

    @MainActor
    func testManageHomeMainSheetStructure() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        let state = app.descendants(matching: .any)["home-manage-state"]
        XCTAssertEqual(state.label, "Ready")
        XCTAssertTrue(app.descendants(matching: .any)["home-context-breakdown"].exists, "The stats card comes from the Home chat's session")
        XCTAssertFalse(app.descendants(matching: .any)["session-model-summary"].exists)
        XCTAssertFalse(app.buttons["Background models"].firstMatch.exists, "Model controls belong only to Home Settings")
        XCTAssertFalse(app.textFields["settings-renderer-search"].exists, "Manage Home carries no settings search")
        XCTAssertFalse(app.staticTexts["Automatic Compaction"].exists, "Home never compacts; it uses chapters")
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-context"].exists, "Home's context is Manage Home's top card, not a sub-sheet")
        for row in ["home-manage-profile", "home-manage-memory-browser", "home-manage-chapters", "home-manage-tasks"] {
            XCTAssertTrue(app.descendants(matching: .any)[row].exists, row)
        }
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-pause"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-disable"].exists)
        XCTAssertFalse(app.staticTexts["Stop response"].exists, "Stop is the composer's control, not a Manage Home row")
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-stop"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Home · ")).firstMatch.exists, "The state is a pill, not a row")
        keepScreenshot(named: "manage-home-sheet")
    }



    /// Every Manage Home sub-sheet opens at the medium detent, as the Manage Session
    /// sub-sheets do: its frame stays well short of the full window.
    @MainActor
    func testManageHomeSubSheetsOpenAtMedium() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        let windowHeight = app.windows.firstMatch.frame.height
        for (row, done) in [("home-manage-profile", "home-sheet-done-profile"), ("home-manage-memory-browser", "home-sheet-done-memory"),
                            ("home-manage-chapters", "home-sheet-done-chapters"), ("home-manage-tasks", "home-sheet-done-tasks")] {
            tapManageRow(app, row)
            let doneButton = app.buttons[done]
            XCTAssertTrue(doneButton.waitForExistence(timeout: 5), row)
            XCTAssertLessThan(doneButton.frame.minY, windowHeight * 0.6, "\(row) must open at the medium detent")
            doneButton.tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 5), row)
        }
    }


    @MainActor
    func testHomeCrossSurfaceProofMatrix() {
        continueAfterFailure = false
        let sheets: [(row: String, doneID: String, content: String, name: String)] = [
            ("home-manage-memory-browser", "memory", "home-memory-row-39", "memory-browser"),
            ("home-manage-chapters", "chapters", "home-chapter-2", "chapters"),
            ("home-manage-tasks", "tasks", "home-task-active", "tasks"),
        ]
        for appearance in ["light", "dark"] {
            for type in ["normal", "accessibility"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-paused"]
                if appearance == "dark" { app.launchArguments.append("-home-dark") }
                if type == "accessibility" { app.launchArguments.append("-home-accessibility-type") }
                app.launch()
                XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
                app.buttons["home-pinned-row"].tap()
                XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
                XCTAssertTrue(app.textViews.firstMatch.isHittable)
                openManageHome(app)
                let state = app.descendants(matching: .any)["home-manage-state"]
                XCTAssertTrue(state.label.contains("Paused"), state.label)
                XCTAssertTrue(app.descendants(matching: .any)["home-manage-resume"].exists)
                XCTAssertFalse(app.descendants(matching: .any)["home-manage-stop"].exists)
                keepScreenshot(named: "manage-home-\(appearance)-\(type)")
                for sheet in sheets {
                    tapManageRow(app, sheet.row)
                    XCTAssertTrue(app.descendants(matching: .any)[sheet.content].waitForExistence(timeout: 5), app.debugDescription)
                    keepScreenshot(named: "proof-\(appearance)-\(type)-\(sheet.name)")
                    app.buttons["home-sheet-done-\(sheet.doneID)"].tap()
                    XCTAssertTrue(state.waitForExistence(timeout: 5), app.debugDescription)
                }
                app.terminate()
            }
        }

        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-reconnect-after-task-list"]
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        // The main sheet reads the task list for its Tasks subtitle, then the Tasks sheet
        // reads it again: two reads before the reconnect.
        let reads = app.staticTexts["fixture.home-task-list-reads"]
        XCTAssertTrue(waitForLabel(reads, containing: "task-list-reads:1", timeout: 10))
        tapManageRow(app, "home-manage-tasks")
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5), app.debugDescription)
        // The fixture reconnects once after the first read; the mounted sheet must re-read.
        XCTAssertTrue(waitForLabel(reads, containing: "task-list-reads:3", timeout: 10), "Mounted sheet did not re-read after reconnect")
        XCTAssertTrue(app.buttons["home-task-active"].exists)
        keepScreenshot(named: "proof-reconnected-tasks")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3))
        app.activate()
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForLabel(reads, containing: "task-list-reads:4", timeout: 10), "Foreground did not start a fresh tasks read")
        keepScreenshot(named: "proof-background-foreground-tasks")
        app.buttons["home-sheet-done-tasks"].tap()
        app.terminate()
    }

    /// A model queue edits in the shared settings list editor: new entries come from
    /// the shared model picker (only what the Gateway serves, never a virtual model),
    /// rows move earlier or later, and Save sends the ordered list once through the
    /// settings receipt. Reopening reads the canonical value.
    @MainActor
    func testHomeBackgroundModelQueueEditsInSharedListEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-unconfigured", "-home-sheet-delayed-status"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        revealHomeSetting(app, "Background models")
        let inheritedSummary = app.buttons["Background models"].firstMatch.value as? String
        XCTAssertFalse(inheritedSummary?.isEmpty ?? true, "The inherited queue must have its served summary")
        app.buttons.matching(NSPredicate(format: "label == %@", "Background models")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
        for name in ["Memory Model B", "Memory Model A"] {
            XCTAssertTrue(app.buttons["Add model"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            app.buttons.matching(NSPredicate(format: "label == %@", "Add model")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
            let choice = modelPickerRow(app, name)
            XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(modelPickerRow(app, "Virtual model").exists, "A queue names physical models only")
            choice.tap()
        }
        XCTAssertTrue(app.staticTexts["fixture/memory-a"].waitForExistence(timeout: 5), app.debugDescription)
        // The first row cannot move earlier; the last cannot move later.
        XCTAssertFalse(app.buttons["Move fixture/memory-b earlier"].isEnabled)
        XCTAssertFalse(app.buttons["Move fixture/memory-a later"].isEnabled)
        app.buttons["Move fixture/memory-a earlier"].tap()
        XCTAssertLessThan(app.staticTexts["fixture/memory-a"].frame.minY, app.staticTexts["fixture/memory-b"].frame.minY)
        keepScreenshot(named: "home-background-models-editor")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-configured-model"], containing: "fixture/memory-a,fixture/memory-b", timeout: 5))
        let row = app.buttons["Background models"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let converged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "2 models"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [converged], timeout: 8), .completed)
        keepScreenshot(named: "home-background-models-configured")
        tapScrolling(row, in: app)
        XCTAssertTrue(app.staticTexts["fixture/memory-a"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.staticTexts["fixture/memory-a"].frame.minY, app.staticTexts["fixture/memory-b"].frame.minY,
                          "The compact summary must not replace the canonical ordered list")
        closeTopSheet(app)
        let reset = app.buttons["settings-row-model.queue_role_background__role_background-reset"]
        reveal(reset, in: app)
        reset.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:2", timeout: 5))
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, inheritedSummary, "Unset restores the served inherited summary, not a copied queue")
        closeTopSheet(app)
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.staticTexts["fixture.home-control-count"].label.contains("control-count:2"),
                      "Save and unset each send one accepted command")
    }

    @MainActor
    func testHomeSettingsRefusalAndEmptyCatalogAndBrowserCapability() {
        continueAfterFailure = false
        for state in ["empty-models", "configure-refused", "browser-unsupported"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-\(state)"]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
            app.buttons["home-pinned-row"].tap()
            openManageHome(app)
            if state == "browser-unsupported" {
                XCTAssertFalse(app.descendants(matching: .any)["home-manage-memory-browser"].exists)
                XCTAssertTrue(app.descendants(matching: .any)["home-context-breakdown"].exists)
            }
            if state == "empty-models" {
                revealHomeSetting(app, "Background models")
                app.buttons.matching(NSPredicate(format: "label == %@", "Background models")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
                XCTAssertTrue(app.buttons["Add model"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                app.buttons.matching(NSPredicate(format: "label == %@", "Add model")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
                XCTAssertTrue(app.staticTexts["No Models"].waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertFalse(modelPickerRow(app, "Memory Model B").exists)
            } else if state == "configure-refused" {
                revealHomeSetting(app, "Background models")
                app.buttons.matching(NSPredicate(format: "label == %@", "Background models")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
                XCTAssertTrue(app.buttons["Add model"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                app.buttons.matching(NSPredicate(format: "label == %@", "Add model")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
                let choice = modelPickerRow(app, "Memory Model B")
                XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
                choice.tap()
                app.buttons["Save"].firstMatch.tap()
                XCTAssertTrue(app.staticTexts["Memory configuration refused"].waitForExistence(timeout: 5))
                XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-configured-model"], containing: "none", timeout: 3))
            }
            keepScreenshot(named: "home-settings-\(state)")
            app.terminate()
        }
    }

    /// Stop is the composer's control: it stops the accepted activation through the
    /// same canonical operation, while Pause never does.
    @MainActor
    func testManageHomeStatesAndStopOwner() {
        for (phase, label) in [("ready", "Ready"), ("active", "Working"), ("paused", "Paused"),
                               ("blocked", "Memory blocked"), ("unconfigured", "Memory setup needed"),
                               ("rollover-pending", "Recovery needed")] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-\(phase)"]
            app.launch()
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
            app.buttons["home-pinned-row"].tap()
            openManageHome(app)
            let state = app.descendants(matching: .any)["home-manage-state"]
            XCTAssertTrue(state.label.contains(label), state.label)
            keepScreenshot(named: "manage-home-\(phase)")
            if phase == "active" {
                tapManageRow(app, "home-manage-pause")
                // Pause leaves the accepted response running: the phase, not the memory, owns the pill.
                XCTAssertTrue(waitForLabel(state, containing: "Working", timeout: 5))
                app.buttons["home-sheet-done-manage"].tap()
                XCTAssertTrue(app.buttons["Stop Tron"].waitForExistence(timeout: 5), "The composer owns Stop")
                app.buttons["Stop Tron"].tap()
                XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-abort-count"], containing: "abort-count:1", timeout: 5))
                openManageHome(app)
                XCTAssertTrue(waitForLabel(app.descendants(matching: .any)["home-manage-state"], containing: "Paused", timeout: 8))
            }
            app.terminate()
        }
    }

    @MainActor
    func testManageHomeUnresolvedDisableRetainsCompletionControl() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-control-unresolved"]
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-disable")
        confirmHomeAction(app)
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-check-completion"].waitForExistence(timeout: 8),
                      "An unresolved disable must offer only the completion check")
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].exists)
        // Authoritative disable does not resolve an unknown command receipt: the
        // ring still manages Home, and the fresh read shows Disabled.
        openManageHome(app)
        XCTAssertTrue(waitForLabel(app.descendants(matching: .any)["home-manage-state"], containing: "Disabled", timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-check-completion"].exists)
        keepScreenshot(named: "manage-home-unresolved-disable")
        app.terminate()
    }

    @MainActor
    func testManageHomePauseResumeDisableKeepsChat() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        let row = app.buttons["home-pinned-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 10))
        openManageHome(app)
        let state = app.descendants(matching: .any)["home-manage-state"]
        tapManageRow(app, "home-manage-pause")
        XCTAssertTrue(waitForLabel(state, containing: "Paused", timeout: 5))
        keepScreenshot(named: "manage-home-paused")
        tapManageRow(app, "home-manage-resume")
        XCTAssertTrue(waitForLabel(state, containing: "Ready", timeout: 5))
        // Disable is destructive: a cancelled confirmation keeps Home enabled.
        tapManageRow(app, "home-manage-disable")
        XCTAssertTrue(app.buttons["confirmation-cancel"].waitForExistence(timeout: 5))
        app.buttons["confirmation-cancel"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "Ready", timeout: 3))
        tapManageRow(app, "home-manage-disable")
        confirmHomeAction(app)
        XCTAssertTrue(waitForLabel(state, containing: "Disabled", timeout: 5))
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].exists)
        // Confirmed disable returns the ring to Manage Session.
        XCTAssertTrue(waitForLabel(app.buttons["session-context-button"], containing: "Manage Session", timeout: 8))
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Manage Home"].exists)
        app.terminate()
    }

    /// Home's role title ignores a generated canonical session name. The leading
    /// toolbar action opens the existing terminal route, never a Home-specific shell.
    @MainActor
    func testHomeTitleAndManageTerminalUseCanonicalRoute() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["home-pinned-row"].label.contains("Home"))
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.staticTexts["Home fixture chat"].exists)
        keepScreenshot(named: "home-canonical-title")
        openManageHome(app)
        let terminal = app.buttons["manage-home-terminal"]
        let done = app.buttons["home-sheet-done-manage"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertTrue(terminal.isEnabled)
        XCTAssertLessThan(terminal.frame.midX, app.frame.width / 2)
        XCTAssertEqual(terminal.frame.midY, done.frame.midY, accuracy: 8)
        XCTAssertGreaterThan(done.frame.minY, app.frame.height * 0.4, "Manage Home still opens at medium")
        keepScreenshot(named: "manage-home-leading-terminal")
        terminal.tap()
        XCTAssertTrue(app.staticTexts["Terminal unavailable"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Fixture terminal unavailable for home-session"].exists,
                      "The standard TerminalSheet must request terminal.list for the exact Home session")
        keepScreenshot(named: "home-terminal-established-unavailable-state")
    }

    @MainActor
    func testManageHomeTerminalRespectsUnavailableCapability() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-terminal-unsupported"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        let terminal = app.buttons["manage-home-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertFalse(terminal.isEnabled)
        keepScreenshot(named: "manage-home-terminal-unsupported")
    }

    /// Manage Home opens at medium, drags to large, and lists every Home entry. Its
    /// child sheets keep their own lifetime and return to it; a sealed chapter opens
    /// read-only and never claims the Home status.
    @MainActor
    func testManageHomeOpensAtMediumFromRingAndHomeGearOpensSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
        let homeControlCount = app.staticTexts["fixture.home-control-count"]
        XCTAssertTrue(homeControlCount.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 10), app.debugDescription)
        // Home retains its direct Settings gear; ordinary chats use Manage Session.
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.navigationBars.buttons["Manage Home"].exists)
        gear.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-state"].exists)
        XCTAssertTrue(homeControlCount.label.contains("control-count:0"), "Opening Home Settings must not apply controls")
        keepScreenshot(named: "home-gear-settings-sheet")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 5), app.debugDescription)
        // Its context ring opens Manage Home at the medium detent, like Manage Session.
        openManageHome(app)
        let state = app.descendants(matching: .any)["home-manage-state"]
        XCTAssertTrue(state.label.contains("Ready"), state.label)
        let done = app.buttons["home-sheet-done-manage"]
        let windowHeight = app.windows.firstMatch.frame.height
        let mediumTop = done.frame.minY
        XCTAssertGreaterThan(mediumTop, windowHeight * 0.40, "Manage Home must open at its medium detent")
        keepScreenshot(named: "manage-home-medium")
        XCTAssertTrue(homeControlCount.label.contains("control-count:0"), "Opening Manage Home must not apply controls")
        // It drags to large from the sheet title.
        let title = app.staticTexts["Manage Home"].firstMatch
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in done.frame.minY < mediumTop - 100 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed, "Manage Home must drag to its large detent")
        keepScreenshot(named: "manage-home-large")
        XCTAssertFalse(app.descendants(matching: .any)["session-model-summary"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-chapters"].exists)
        for row in ["home-manage-memory-browser", "home-manage-tasks",
                    "home-manage-pause", "home-manage-disable"] {
            XCTAssertTrue(app.descendants(matching: .any)[row].exists, row)
        }
        // A child surface keeps its own sheet lifetime above Manage Home and returns to it.
        tapManageRow(app, "home-manage-memory-browser")
        XCTAssertTrue(app.descendants(matching: .any)["home-memory-row-39"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["home-sheet-done-memory"].tap()
        XCTAssertTrue(state.waitForExistence(timeout: 5), app.debugDescription)
        // The Chapters child sheet shows the whole ledger (#740): state, dates and
        // size against the limits; a sealed chapter opens read-only and never
        // claims the Home status.
        tapManageRow(app, "home-manage-chapters")
        XCTAssertTrue(app.buttons["home-chapter-2"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["home-chapter-1"].exists)
        keepScreenshot(named: "home-chapters-sheet")
        app.buttons["home-chapter-1"].tap()
        tapManageRow(app, "home-chapter-open-transcript")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-opened-session"], containing: "opened-session:home-chapter-sealed", timeout: 10))
        XCTAssertTrue(waitForLabel(app.buttons["session-context-button"], containing: "Manage Session", timeout: 10), "A read-only chapter chat must not claim Home")
        XCTAssertFalse(app.buttons["Manage Home"].exists)
        keepScreenshot(named: "home-chapter-read-only")
        // Opening a chapter replaced the single chat route, so Back returns to the
        // dashboard; an ordinary chat's gear opens Settings, as Home's does.
        app.buttons["Back"].tap()
        let ordinary = app.buttons["session-row-home-shell-fixture:ordinary-session"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 10), app.debugDescription)
        ordinary.tap()
        XCTAssertTrue(app.staticTexts["Ordinary session chat"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Manage Home"].exists)
        let ordinaryGear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(ordinaryGear.waitForExistence(timeout: 5), app.debugDescription)
        ordinaryGear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-state"].exists)
        XCTAssertTrue(homeControlCount.label.contains("control-count:0"), "Opening ordinary-chat Settings must not apply Home controls")
        keepScreenshot(named: "ordinary-chat-settings-sheet")
    }

    @MainActor
    private func confirmHomeAction(_ app: XCUIApplication) {
        let confirm = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "confirmation-primary")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
    }

    @MainActor
    private func revokeHomePermission(_ app: XCUIApplication, _ label: String) {
        let revoke = app.buttons[label]
        reveal(revoke, in: app)
        XCTAssertTrue(revoke.waitForExistence(timeout: 5), app.debugDescription)
        revoke.tap()
        confirmHomeAction(app)
    }

    @MainActor
    func testHomeTaskEmptyAndRecoveryFence() {
        continueAfterFailure = false
        for state in ["tasks-empty", "task-fenced"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-\(state)"]
            app.launch()
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
            app.buttons["home-pinned-row"].tap()
            openManageHome(app)
            tapManageRow(app, "home-manage-tasks")
            if state == "tasks-empty" {
                XCTAssertTrue(app.staticTexts["No tasks"].waitForExistence(timeout: 5))
                keepScreenshot(named: "home-tasks-empty")
                app.buttons["home-sheet-done-tasks"].tap()
                tapManageRow(app, "home-manage-settings")
                reveal(app.staticTexts["Home task namespace refused: not-initialized"], in: app)
                XCTAssertTrue(app.staticTexts["Home task namespace refused: not-initialized"].exists)
                XCTAssertFalse(app.buttons["Reconfirm permissions"].exists)
            } else {
                XCTAssertTrue(app.staticTexts["Task recovery needed"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["unsafe-state"].exists)
                XCTAssertFalse(app.buttons["home-task-active"].exists)
                keepScreenshot(named: "home-task-recovery-fenced")
            }
            app.terminate()
        }
    }

    /// The row stays routable while the successor is reserved: it opens the sealed
    /// predecessor, the send goes through the logical Home route, and the chat
    /// follows Home to the chapter it names once that send materializes it.
    @MainActor
    func testHomeRolloverPendingRoutesSendAndFollowsSuccessor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-rollover"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        XCTAssertTrue(waitForLabel(app.descendants(matching: .any)["home-manage-state"], containing: "Recovery needed", timeout: 10))
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-opened-session"], containing: "opened-session:home-session", timeout: 10))
        let composer = app.textViews["Message input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("After rollover")
        let send = app.buttons["Send message"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)], timeout: 5), .completed)
        send.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-prompt-route"], containing: "prompt-route:home.prompt", timeout: 10))
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-opened-session"], containing: "opened-session:home-successor", timeout: 20))
        XCTAssertTrue(waitForLabel(app.buttons["session-context-button"], containing: "Manage Home", timeout: 10), "The successor chat did not claim the Home status")
        keepScreenshot(named: "home-rollover-followed")
    }



    @MainActor
    func testManageHomeRejectsStaleRouteAction() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-stale-route"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        // Mounting Manage Home installs the retained action; the stale invocation
        // after the profile switch must be refused by the sheet's identity fences.
        openManageHome(app)
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.buttons["fixture.invoke-stale-home-action"].waitForExistence(timeout: 5))
        app.buttons["fixture.invoke-stale-home-action"].tap()
        XCTAssertTrue(app.staticTexts["fixture.stale-action-finished"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:0", timeout: 3))
        XCTAssertTrue(app.staticTexts["fixture.home-diagnostics"].label.contains("competing-profile"))
        keepScreenshot(named: "manage-home-stale-route-refused")
    }

    @MainActor
    func testManageHomeAcceptedControlContinuesInBackground() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-control-delayed"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-pause")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 3))
        XCTAssertTrue(app.staticTexts["fixture.home-command-state"].label.contains("running"))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3))
        // The fixture resolves after six seconds, while presentation is retired.
        Thread.sleep(forTimeInterval: 7)
        app.activate()
        let state = app.descendants(matching: .any)["home-manage-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), app.debugDescription)
        if app.descendants(matching: .any)["home-manage-check-completion"].waitForExistence(timeout: 2) {
            app.descendants(matching: .any)["home-manage-check-completion"].tap()
        }
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-command-state"], containing: "idle", timeout: 5))
        XCTAssertTrue(waitForLabel(state, containing: "Paused", timeout: 8))
        XCTAssertTrue(app.staticTexts["fixture.home-control-count"].label.contains("control-count:1"))
        keepScreenshot(named: "manage-home-background-accepted-paused")
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 5))
    }

    /// Manage Home's pending settings changes (settings-model.md 5.5): each row
    /// is decided by its own digest-bound Approve or Decline, and a decided row leaves.
    @MainActor
    func testManageHomeSettingsApprovalsApproveAndDecline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-settings-approvals"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        let header = app.descendants(matching: .any)["settings-approvals-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), app.debugDescription)
        let approveRow = app.descendants(matching: .any)["settings-approval-settings-request-approve"]
        let declineRow = app.descendants(matching: .any)["settings-approval-settings-request-decline"]
        XCTAssertTrue(approveRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(declineRow.exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings-approval-settings-request-chat"].exists,
                       "A chat agent's request belongs to that chat's Manage Session, not Manage Home")
        // The exact change, who asked and the confirm text, all Gateway text.
        for text in ["Not set → Trusted", "Asked by Home", "Asked by Home task nightly-sync", "/work/other", "Trusting a project lets its files run"] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 5), text)
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Expires in")).firstMatch.exists, "The expiry reads as a relative time")
        keepScreenshot(named: "home-settings-approvals-pending")

        tapScrolling(app.buttons["settings-approval-approve-settings-request-approve"], in: app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-decisions"], containing: "approved:settings-request-approve", timeout: 5))
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
        XCTAssertTrue(approveRow.waitForNonExistence(timeout: 5))

        tapScrolling(app.buttons["settings-approval-decline-settings-request-decline"], in: app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-decisions"], containing: "declined:settings-request-decline", timeout: 5))
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:2", timeout: 5))
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "No pending Home change leaves the approvals section empty")
        keepScreenshot(named: "home-settings-approvals-decided")
    }

    /// Editors and inspection are siblings, not nested buttons. Identify the
    /// actual value action without depending on SwiftUI wrapper depth/order.
    @MainActor
    private func settingEditor(_ row: XCUIElement) -> XCUIElement {
        row.buttons.matching(NSPredicate(format: "NOT identifier ENDSWITH '-source' AND NOT identifier ENDSWITH '-reset'")).firstMatch
    }

    /// Scrolls the sheet until the control is hittable, then taps it.
    @MainActor
    private func tapScrolling(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        element.tap()
    }

    /// A Home sheet belongs to the profile that opened it: once the selected profile
    /// changes, the sheet is dismissed rather than left presenting another Mac's Home.
    @MainActor
    func testHomeSheetDismissesWhenProfileSwitches() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-switch-profile-after-task-open"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-tasks")
        XCTAssertTrue(app.buttons["home-sheet-done-tasks"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5), app.debugDescription)
        // Opening a task is the sheet's next read; the fixture then selects another profile through
        // the production switch, which must release the chat and every Home sheet it presents.
        app.buttons["home-task-active"].tap()
        XCTAssertTrue(app.buttons["home-sheet-done-tasks"].waitForNonExistence(timeout: 10),
                      "A profile switch left the Home sheet presented for the previous profile")
    }

    @MainActor
    func testManageHomeBackgroundReconnectAndUnresolvedCompletion() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-control-unresolved"]
        app.launch()
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-pause")
        let state = app.descendants(matching: .any)["home-manage-state"]
        // The unresolved command is the Memory row's subtitle; the state pill keeps the Home phase.
        let memoryRow = app.descendants(matching: .any)["home-manage-memory-browser"]
        XCTAssertTrue(waitForLabel(memoryRow, containing: "unresolved", timeout: 8))
        keepScreenshot(named: "manage-home-unresolved")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(state.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForLabel(memoryRow, containing: "unresolved", timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-pause"].exists)
        tapManageRow(app, "home-manage-check-completion")
        // The first check finds the receipt still pending and must not claim completion.
        XCTAssertTrue(waitForLabel(memoryRow, containing: "unresolved", timeout: 5))
        tapManageRow(app, "home-manage-check-completion")
        XCTAssertTrue(waitForLabel(state, containing: "Paused", timeout: 5))
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
        keepScreenshot(named: "manage-home-reconnected-paused")
        app.terminate()
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Opens Manage Home from the composer's context ring (#748, #799). The ring
    /// names the sheet it opens, so its "Manage Home" label is the claim; the
    /// sheet's state row is the readiness signal.
    @MainActor
    private func openManageHome(_ app: XCUIApplication) {
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForLabel(ring, containing: "Manage Home", timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForEnabled(ring, timeout: 10), app.debugDescription)
        ring.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func tapManageRow(_ app: XCUIApplication, _ id: String) {
        let row = app.descendants(matching: .any)[id]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
    }

    /// A running Home change is shown on the row as an update: the row is not a
    /// set-up or a completion check while the designation is still in flight.
    @MainActor
    func testHomePinnedRowNamesRunningDesignationAsUpdate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-undesignated", "-home-control-delayed"]
        app.launch()
        defer { app.terminate() }
        let row = app.buttons["home-pinned-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(waitForLabel(row, containing: "Updating Home", timeout: 3), row.label)
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    func testHomePinnedRowCapabilityDesignationAndExactProfileRoute() {
        continueAfterFailure = false
        // Capability-off baseline: no pinned row or Manage Home ring; the ordinary session opens unchanged.
        let unsupported = XCUIApplication()
        unsupported.launchArguments = ["-tron-home-dashboard-fixture", "-home-capability-absent"]
        unsupported.launch()
        XCTAssertFalse(unsupported.buttons["home-pinned-row"].exists)
        let ordinary = unsupported.buttons["session-row-home-shell-fixture:ordinary-session"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 10), unsupported.debugDescription)
        ordinary.tap()
        XCTAssertTrue(unsupported.staticTexts["Ordinary session chat"].waitForExistence(timeout: 10))
        XCTAssertFalse(unsupported.buttons["Manage Home"].exists)
        keepScreenshot(named: "proof-capability-off-ordinary-chat")
        unsupported.terminate()

        let ready = XCUIApplication()
        ready.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        ready.launch()
        let home = ready.buttons["home-pinned-row"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        XCTAssertTrue(ready.navigationBars.staticTexts["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(ready.staticTexts["fixture.home-diagnostics"].label.contains("home-shell-fixture"))
        ready.terminate()

        for state in ["undesignated", "disabled", "missing-session"] {
            let setup = XCUIApplication()
            setup.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-\(state)"]
            setup.launch()
            let designate = setup.buttons["home-pinned-row"]
            XCTAssertTrue(designate.waitForExistence(timeout: 10), state)
            designate.tap()
            XCTAssertTrue(setup.navigationBars.staticTexts["Home"].waitForExistence(timeout: 10), state)
            XCTAssertTrue(setup.staticTexts["fixture.home-diagnostics"].label.contains("home-shell-fixture"))
            setup.terminate()
        }
    }

    @MainActor
    func testHomeRowRetainsStatusAcrossRepeatedBackNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-navigation-refresh"]
        app.launch()
        defer { app.terminate() }
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(waitForLabel(home, containing: "Ready", timeout: 10), app.debugDescription)
        for (index, session) in ["ordinary", "home", "ordinary", "home"].enumerated() {
            let row = session == "home" ? home : app.buttons["session-row-home-shell-fixture:ordinary-session"]
            row.tap()
            XCTAssertTrue(app.navigationBars.staticTexts[session == "home" ? "Home" : "Ordinary session chat"].waitForExistence(timeout: 10))
            app.buttons["Back"].tap()
            // Sample the native row repeatedly while the Gateway response is held.
            // Waiting for Ready here would hide precisely the reported flicker.
            for frame in 0..<3 {
                keepScreenshot(named: "853-simulator-return-\(index)-frame-\(frame)")
                XCTAssertTrue(home.exists, "Home disappeared on return \(index), frame \(frame)")
                XCTAssertTrue(home.label.contains("Ready"), "Retained status replaced: \(home.label)")
                XCTAssertTrue(home.isEnabled)
            }
        }
    }

    @MainActor
    func testHomeChatStatusPollingResumesAfterCoveredManageHomeSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture"]
        app.launch()
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        home.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["fixture.home-diagnostics"].label.contains("home-shell-fixture"))
        let count = app.staticTexts["fixture.home-status-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let statusCount = { Int(count.label.split(separator: ":").last ?? "0") ?? 0 }
        // The Home chat's context ring opens Manage Home (#725, #799); its one status
        // read must settle inside the baseline window below, and it never polls.
        openManageHome(app)
        XCTAssertTrue(app.buttons["home-sheet-done-manage"].waitForExistence(timeout: 5))
        // Let a read admitted before cover settle, then require a quiet interval
        // longer than the five-second fallback while the managed sheet is open.
        Thread.sleep(forTimeInterval: 1)
        let coveredBaseline = statusCount()
        Thread.sleep(forTimeInterval: 5.5)
        XCTAssertEqual(statusCount(), coveredBaseline, "Home status reads continued while Manage Home covered the chat")
        app.buttons["home-sheet-done-manage"].tap()
        let increased = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            statusCount() > coveredBaseline
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [increased], timeout: 7), .completed)
        app.terminate()
    }

    // Failure modes (#748, #799): the Home chat's composer context ring opens the ordinary
    // Manage Session sheet, whose controls Home refuses; or the fix routes an ordinary
    // chat's ring away from Manage Session.
    @MainActor
    func testComposerContextRingOpensManageHomeInHomeAndManageSessionElsewhere() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 10), app.debugDescription)
        // The ring's claim proves the Home status is routed before the ring is judged.
        XCTAssertTrue(waitForLabel(app.buttons["session-context-button"], containing: "Manage Home", timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["Settings"].exists)
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(ring.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForEnabled(ring, timeout: 10), app.debugDescription)
        ring.tap()
        XCTAssertFalse(app.staticTexts["Manage Session"].waitForExistence(timeout: 2), "The Home chat's ring opened Manage Session")
        let state = app.descendants(matching: .any)["home-manage-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "home-ring-manage-home")
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Home"].waitForExistence(timeout: 5))
        // VoiceOver names the ring by what it opens.
        XCTAssertEqual(ring.label, "Manage Home")

        // An ordinary chat's ring keeps opening Manage Session.
        app.buttons["Back"].tap()
        let ordinary = app.buttons["session-row-home-shell-fixture:ordinary-session"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 10), app.debugDescription)
        ordinary.tap()
        XCTAssertTrue(app.staticTexts["Ordinary session chat"].waitForExistence(timeout: 10))
        let ordinaryRing = app.buttons["session-context-button"]
        XCTAssertTrue(ordinaryRing.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForEnabled(ordinaryRing, timeout: 10), app.debugDescription)
        XCTAssertEqual(ordinaryRing.label, "Manage Session")
        ordinaryRing.tap()
        XCTAssertTrue(app.staticTexts["Manage Session"].waitForExistence(timeout: 5), app.debugDescription)
        let manageSessionDone = app.buttons["Done"].firstMatch
        XCTAssertTrue(manageSessionDone.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThan(manageSessionDone.frame.minY, app.windows.firstMatch.frame.height * 0.40, "Manage Session opens at medium (the detent Manage Home matches)")
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-state"].exists)
        keepScreenshot(named: "ordinary-ring-manage-session")
        manageSessionDone.tap()
        // The gear opens Settings (this Mac and iPhone) in every chat; the ring is the chat's own.
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "The ordinary gear must name and open Settings")
        gear.tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-state"].exists)
        keepScreenshot(named: "ordinary-gear-settings")
        app.buttons["settings-done"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Ordinary session chat"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:0", timeout: 5),
                      "Opening and dismissing management sheets must not apply Home controls")
    }

    /// Opening an inherited context window must not create a Chat override.
    /// Exercise Home Settings and its shared anchored editor, not a duplicate control fixture.
    @MainActor
    func testManageHomeContextWindowOpenDismissDoesNotWrite() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(waitForLabel(ring, containing: "Manage Home", timeout: 10))
        ring.tap()
        revealHomeSetting(app, "Context window")
        let controls = app.buttons.matching(identifier: "settings-number-control")
        let control = controls.element(boundBy: controls.count - 1)
        reveal(control, in: app)
        XCTAssertTrue(control.isHittable, app.debugDescription)
        let inherited = control.value as? String
        keepScreenshot(named: "manage-home-context-window-row")
        control.tap()
        let slider = app.descendants(matching: .any)["settings-number-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "manage-home-context-window-editor")
        // Tap the overlay's backdrop inside the sheet, not the status bar outside its host.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 10, dy: min(app.frame.maxY - 70, slider.frame.maxY + 80))).tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5), "Dismiss must retire the editor")
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertEqual(control.value as? String, inherited)
        closeTopSheet(app)
        app.buttons["home-sheet-done-manage"].tap()
        app.buttons["Back"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:0", timeout: 5),
                      "Opening and dismissing an inherited value must not call settings.change")
    }

    /// A model row in the shared ModelPicker, named by the model's display name.
    /// A collapsed provider section is opened first, as a user would.
    private func modelPickerRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let collapsed = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@ AND value == %@", " models", "collapsed")).firstMatch
        if collapsed.waitForExistence(timeout: 3) { collapsed.tap() }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// Opens Home Settings and reveals an inline Model or Workers control.
    @MainActor
    @discardableResult
    private func revealHomeSetting(_ app: XCUIApplication, _ label: String) -> Int {
        tapManageRow(app, "home-manage-settings")
        let controls = app.buttons.matching(NSPredicate(format: "label == %@", label))
        reveal(controls.firstMatch, in: app)
        XCTAssertTrue(controls.allElementsBoundByIndex.contains(where: \.isHittable), app.debugDescription)
        return 1
    }

    @MainActor
    func testManageHomeProfileSettingChangeReopenAndCancel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        var opened = revealHomeSetting(app, "Worker thinking")
        app.buttons.matching(NSPredicate(format: "label == %@", "Worker thinking")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
        XCTAssertTrue(app.buttons["settings-option-Low"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["settings-option-Low"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
        for _ in 0..<opened { closeTopSheet(app) }
        app.buttons["home-sheet-done-manage"].tap()
        openManageHome(app)
        opened = revealHomeSetting(app, "Worker thinking")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Worker thinking", "Low")).firstMatch
            .waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "manage-home-profile-worker-thinking")
        app.buttons.matching(NSPredicate(format: "label == %@", "Worker thinking")).allElementsBoundByIndex.last(where: \.isHittable)?.tap()
        XCTAssertTrue(app.buttons["settings-option-Medium"].waitForExistence(timeout: 5))
        closeTopSheet(app) // the choice picker, without choosing
        for _ in 0..<opened { closeTopSheet(app) }
        app.buttons["home-sheet-done-manage"].tap()
        XCTAssertTrue(app.staticTexts["fixture.home-control-count"].label.contains("control-count:1"), "Dismissing a choice must not change Profile")
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == true")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    // Home is never an ordinary session row: while it is Working, its pinned row
    // is the only Home entry in the dashboard (#756).
    @MainActor
    func testHomeIsNotAnOrdinarySessionRowWhileWorking() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-active"]
        app.launch()
        defer { app.terminate() }
        let pinned = app.buttons["home-pinned-row"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(pinned.label.contains("Working"), pinned.label)
        XCTAssertTrue(app.buttons["session-row-home-shell-fixture:ordinary-session"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["session-row-home-shell-fixture:home-session"].exists, "Home must not be an ordinary session row")
    }

    @MainActor
    func testBlockedHomeRowDoesNotClaimReadiness() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-blocked"]
        app.launch()
        let row = app.buttons["home-pinned-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Blocked"), row.label)
        XCTAssertFalse(row.label.contains("Ready"), row.label)
        app.terminate()
    }

    @MainActor
    func testHomePinnedRowLightDarkAndAccessibilityCaptures() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            for type in ["normal", "accessibility"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
                if appearance == "dark" { app.launchArguments.append("-home-dark") }
                if type == "accessibility" { app.launchArguments.append("-home-accessibility-type") }
                app.launch()
                XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons["session-row-home-shell-fixture:ordinary-session"].exists)
                keepScreenshot(named: "home-pinned-\(appearance)-\(type)")
                app.terminate()
            }
        }
    }

    // Failure modes: an unexplained disabled control; pending work mistaken for
    // a lock; browsing/dismissal blocked; receipt settlement leaving controls stuck.
    @MainActor
    func testConfigurationFeedbackExplainsLockAndPendingWithoutBlockingBrowsing() {
        configurationFeedbackJourney(appearance: "light")
    }

    @MainActor
    func testConfigurationFeedbackExplainsLockAndPendingWithoutBlockingBrowsingInDark() {
        configurationFeedbackJourney(appearance: "dark")
    }

    /// A running chat's Manage Session stays locked while the Gateway rebaselines
    /// it: the lock and the disabled Thinking control never blink.
    @MainActor
    func testRunningConfigurationLockHoldsAcrossRebaselines() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Manage running session"].waitForExistence(timeout: 5))
        app.buttons["Manage running session"].tap()
        let thinking = app.buttons["thinking-level-control"]
        let lock = app.buttons["Why configuration is unavailable"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5), app.debugDescription)
        var samples: [String] = []
        for _ in 0..<30 {
            samples.append("\(lock.exists ? "L" : "-")\(thinking.exists ? (thinking.isEnabled ? "E" : "D") : "?")")
        }
        XCTAssertEqual(Set(samples), ["LD"], "Lock/Thinking across rebaselines: \(samples.joined(separator: " "))")
    }

    @MainActor
    private func configurationFeedbackJourney(appearance: String) {
        continueAfterFailure = false
        // Keyboard/search animation monitoring belongs to one XCTest automation
        // session. Each appearance gets its own case, not a second launch under
        // the first launch's animation observer (which can wait 60s per action).
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", appearance]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        let thinking = app.buttons["thinking-level-control"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        XCTAssertFalse(thinking.isEnabled)
        keepScreenshot(named: "configuration-lock-\(appearance)")
        let explanation = app.buttons["Why configuration is unavailable"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 3), "A disabled control needs a touch-accessible explanation")
        explanation.tap()
        XCTAssertTrue(app.staticTexts["Finishing the session. Configuration will be available shortly."].waitForExistence(timeout: 3))
        keepScreenshot(named: "configuration-lock-explanation-\(appearance)")
        app.buttons["Done"].tap()
        app.buttons["Release terminal settlement"].tap()
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)], timeout: 5)
        thinking.tap()
        let slider = app.descendants(matching: .any)["thinking-level-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        wait(for: [expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: thinking)], timeout: 5)
        let switchModel = app.buttons["Switch Model"]
        XCTAssertTrue(switchModel.isEnabled, "Pending configuration must not block model browsing")
        XCTAssertEqual(switchModel.value as? String, "Applying configuration")
        keepScreenshot(named: "configuration-applying-\(appearance)")
        // Semantic lookup finds the enabled control, but XCTest reports this
        // post-dismissal activation point as not hittable. Use its observed
        // center; the assertions below still require real pending-state browsing.
        switchModel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Model")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 3))
        XCTAssertFalse(selected.isEnabled)
        XCTAssertEqual(selected.value as? String, "Applying configuration")
        keepScreenshot(named: "models-applying-\(appearance)")
        app.buttons["Search models"].tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        search.typeText("Alternative")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alternative Model")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Close search"].tap()
        app.buttons["Done"].tap()
        app.buttons["Complete superseded thinking"].tap()
        XCTAssertTrue(app.staticTexts["Superseded receipt delivered"].waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)], timeout: 5)
        XCTAssertEqual(thinking.value as? String, "Off")
        XCTAssertFalse(app.buttons["Why configuration is unavailable"].exists)
    }

    /// Real native taps through the production nested sheet, with receipt and
    /// snapshot order controlled independently at the Gateway socket boundary.
    @MainActor
    func testModelAcknowledgementResolvesWithoutDismissingPicker() {
        continueAfterFailure = false
        for order in ["snapshot-first", "receipt-first", "superseded"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-session-configuration-fixture", "-model-ack-\(order)"]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
            app.buttons["Stop session"].tap()
            app.buttons["Release terminal settlement"].tap()
            app.buttons["Switch Model"].tap()
            let alternative = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alternative Model")).firstMatch
            let original = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Model")).firstMatch
            XCTAssertTrue(alternative.waitForExistence(timeout: 5))
            alternative.tap()
            wait(for: [expectation(for: NSPredicate(format: "value == %@", "Applying configuration"), evaluatedWith: alternative)], timeout: 2)
            XCTAssertFalse(original.isEnabled, "Rapid replacement choices are refused while one intent owns the receipt")
            XCTAssertFalse(alternative.isEnabled)
            keepScreenshot(named: "model-\(order)-pending-open")
            let confirmed = order == "superseded" ? original : alternative
            wait(for: [expectation(for: NSPredicate(format: "value == %@ AND enabled == true", "Selected"), evaluatedWith: confirmed)], timeout: 10)
            XCTAssertTrue(app.staticTexts["Models"].exists, "Acknowledgement must not dismiss the picker")
            keepScreenshot(named: "model-\(order)-confirmed-open")
            confirmed.tap() // Reselect is a no-op, not another mutation.
            XCTAssertEqual(confirmed.value as? String, "Selected")
            app.buttons["Done"].tap()
            XCTAssertTrue(app.staticTexts["Model requests: 1"].waitForExistence(timeout: 3))
            app.buttons["Switch Model"].tap()
            XCTAssertEqual(confirmed.value as? String, "Selected", "Reopening derives the acknowledged authoritative model")
            if order != "superseded" {
                original.tap()
                wait(for: [expectation(for: NSPredicate(format: "value == %@ AND enabled == true", "Selected"), evaluatedWith: original)], timeout: 10)
                XCTAssertTrue(app.staticTexts["Models"].exists, "A second distinct choice remains usable in this presentation")
            }
            app.buttons["Done"].tap()
            XCTAssertTrue(app.staticTexts[order == "superseded" ? "Model requests: 1" : "Model requests: 2"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["thinking-level-control"].value as? String, "Off")
            app.terminate()
        }
    }

    @MainActor
    func testModelFailureRecoversAndDismissedPendingSelectionReconciles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-model-ack-failure"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        app.buttons["Release terminal settlement"].tap()
        app.buttons["Switch Model"].tap()
        let alternative = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alternative Model")).firstMatch
        let original = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Model")).firstMatch
        XCTAssertTrue(alternative.waitForExistence(timeout: 5))
        alternative.tap()
        let failureNotice = app.descendants(matching: .any)["in-app-notice-card"]
        XCTAssertTrue(failureNotice.waitForExistence(timeout: 10))
        XCTAssertTrue(failureNotice.label.contains("Model choice refused; try again."))
        XCTAssertTrue(failureNotice.isHittable)
        keepScreenshot(named: "model-failure-visible-in-picker")
        XCTAssertTrue(app.staticTexts["Models"].exists)
        XCTAssertEqual(original.value as? String, "Selected")
        XCTAssertTrue(alternative.isEnabled)
        alternative.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == %@", "Applying configuration"), evaluatedWith: alternative)], timeout: 2)
        app.buttons["Done"].tap() // Accepted mutation survives picker dismissal.
        app.buttons["Switch Model"].tap()
        wait(for: [expectation(for: NSPredicate(format: "value == %@ AND enabled == true", "Selected"), evaluatedWith: alternative)], timeout: 10)
        keepScreenshot(named: "model-retry-confirmed-after-reopen")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Model requests: 2"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSupersededThinkingReceiptReleasesMountedConfiguration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        app.buttons["Release terminal settlement"].tap()
        let thinking = app.buttons["thinking-level-control"]
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)], timeout: 5)
        thinking.tap()
        let slider = app.descendants(matching: .any)["thinking-level-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        wait(for: [expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: thinking)], timeout: 5)
        app.buttons["Complete superseded thinking"].tap()
        XCTAssertTrue(app.staticTexts["Superseded receipt delivered"].waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)], timeout: 5)
        XCTAssertTrue(thinking.value as? String == "Off")
        thinking.tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "Another edit must work without reopening Manage Session")
        keepScreenshot(named: "superseded-thinking-receipt-ready")
    }

    @MainActor
    func testPostStopConfigurationWaitsForSettlementThenEnablesWithoutReopening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        let thinking = app.buttons["thinking-level-control"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        XCTAssertFalse(thinking.isEnabled, "Foreground Stop alone must not make settling configuration editable")
        let explanation = app.buttons["Why configuration is unavailable"]
        XCTAssertTrue(explanation.exists)
        explanation.tap()
        XCTAssertTrue(app.staticTexts["Finishing the session. Configuration will be available shortly."].waitForExistence(timeout: 3))
        keepScreenshot(named: "post-stop-configuration-settling")
        app.buttons["Done"].tap()
        app.buttons["Release terminal settlement"].tap()
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: thinking)
        wait(for: [enabled], timeout: 5)
        thinking.tap()
        XCTAssertTrue(app.descendants(matching: .any)["thinking-level-slider"].waitForExistence(timeout: 3))
        keepScreenshot(named: "post-stop-configuration-ready")
    }

    /// The real Manage Session route, not the renderer-only fixture: reset is
    /// fenced to this chat, and reopening shows the authoritative new snapshot.
    @MainActor
    func testManageSessionUsesCurrentDefault() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(app.buttons["Release terminal settlement"].waitForExistence(timeout: 5))
        app.buttons["Release terminal settlement"].tap()
        let models = app.descendants(matching: .any)["session-model-summary"]
        let reset = models.buttons["settings-row-model.thinking_role_chat_-reset"]
        tapScrolling(reset, in: app)
        let thinking = app.buttons["thinking-level-control"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "High"), object: thinking)], timeout: 5), .completed)
        let source = models.buttons["settings-row-model.thinking_role_chat_-source"]
        XCTAssertFalse(app.staticTexts["Value & Source"].exists, "Revert must not also open provenance")
        source.tap()
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForExistence(timeout: 5))
        XCTAssertTrue(showsText("From Mac default at start", in: app))
        closeTopSheet(app)
        XCTAssertFalse(app.switches["Automatic compaction"].exists, "Manage Session must not repeat policy editing")
        XCTAssertTrue(app.buttons["manage-session-compact"].exists, "Manual compaction remains a live action")
        openChatSettings(app)
        let settings = app.descendants(matching: .any)["session-settings-content"]
        XCTAssertFalse(settings.buttons["Switch Model"].exists)
        XCTAssertFalse(settings.buttons["settings-row-model.thinking_role_chat_-reset"].exists, "The canonical reset belongs with live Models")
        tapScrolling(app.buttons["settings-section-context-open"], in: app)
        let compaction = app.switches.matching(NSPredicate(format: "label == %@", "Automatic compaction"))
        XCTAssertTrue(compaction.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(compaction.count, 1, "The policy has one editor in Session Settings")
        closeTopSheet(app) // Compaction policy
        closeTopSheet(app) // Session Settings
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.session-settings-decisions"], containing: "reset:chat:configuration-fixture", timeout: 5))
        closeTopSheet(app) // Manage Session
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        XCTAssertEqual(thinking.value as? String, "High", "Reopening reads the accepted chat snapshot")
        source.tap()
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForExistence(timeout: 5))
        XCTAssertTrue(showsText("From Mac default at start", in: app), "The same accepted origin survives reopening")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.session-settings-decisions"], containing: "reset:chat:configuration-fixture", timeout: 5))
    }

    /// The scope-owned Settings route from the real Manage Session surface.
    @MainActor
    private func openChatSettings(_ app: XCUIApplication) {
        tapScrolling(app.buttons["chat-settings-link"], in: app)
        XCTAssertTrue(app.navigationBars.staticTexts["Session Settings"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Manage Session, Chat Settings and a key's sheet in light and dark at the
    /// largest accessibility type size: every row stays reachable (#766).
    @MainActor
    func testManageSessionSectionsAtAccessibilityTypeInLightAndDark() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-session-configuration-fixture", "-fixture-appearance", appearance,
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
            app.buttons["Stop session"].tap()
            XCTAssertTrue(app.buttons["chat-settings-link"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.buttons["Show all"].exists, "Manage Session never expands settings in place")
            keepScreenshot(named: "766-manage-session-\(appearance)-xxxl-primary")
            app.buttons["Release terminal settlement"].tap()
            let reset = app.descendants(matching: .any)["session-model-summary"].buttons["settings-row-model.thinking_role_chat_-reset"]
            reveal(reset, in: app)
            XCTAssertTrue(reset.isHittable, "The canonical Thinking reset must stay reachable at XXXL")
            // The shared row moves a competing trailing control below its labels at
            // accessibility sizes, so titles and values wrap only at word
            // boundaries (#868): a compact action and a plain value both stack.
            let compactNow = app.buttons["Compact Now"]
            let compactTitle = app.staticTexts["Compact conversation"]
            XCTAssertTrue(compactNow.waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<6 where !(compactNow.isHittable && compactTitle.isHittable) { app.swipeDown() }
            keepScreenshot(named: "868-manage-session-\(appearance)-xxxl-compact-row")
            assertStacked(compactNow, below: compactTitle, in: app)
            let branchTitle = app.staticTexts["Current Branch"]
            let branchValue = app.staticTexts["Unavailable"]
            XCTAssertTrue(branchValue.waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<6 where !(branchTitle.isHittable && branchValue.isHittable) { app.swipeUp() }
            keepScreenshot(named: "868-manage-session-\(appearance)-xxxl-branch-row")
            assertStacked(branchValue, below: branchTitle, in: app)
            for _ in 0..<12 where !app.buttons["chat-settings-link"].isHittable { app.swipeUp() }
            keepScreenshot(named: "766-manage-session-\(appearance)-xxxl-context")
            openChatSettings(app)
            tapScrolling(app.buttons["settings-section-context-open"], in: app)
            let compaction = app.switches["Automatic compaction"]
            reveal(compaction, in: app)
            XCTAssertTrue(compaction.isHittable, "The canonical compaction policy must stay reachable at XXXL")
            keepScreenshot(named: "1325-session-\(appearance)-xxxl-policy")
            app.terminate()
        }
    }

    /// Manage Session's pending change for this chat: a decline is recorded by the
    /// Gateway, and the chat's approvals section then renders nothing.
    @MainActor
    func testManageSessionSettingsApprovalDecline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-session-settings-approvals"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        let row = app.descendants(matching: .any)["settings-approval-settings-session-request"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["settings-approval-settings-other-request"].exists,
                       "Another chat's request does not show in this chat's Manage Session")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "read, bash → read, bash, fetch_page")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Asked by A chat's agent")).firstMatch.exists)
        keepScreenshot(named: "session-settings-approval-pending")

        tapScrolling(app.buttons["settings-approval-decline-settings-session-request"], in: app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.session-settings-decisions"], containing: "declined:settings-session-request", timeout: 5))
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-approvals-header"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["manage-session-rename"].exists, "The decision does not dismiss Manage Session")
        keepScreenshot(named: "session-settings-approval-declined")
    }

    /// A settings-approval push action opens this chat's Manage Session with one
    /// confirmation over its row. The push alone decides nothing; the dialog's button does.
    @MainActor
    func testSettingsApprovalPushApproveConfirmsTheRow() {
        assertSettingsApprovalPushConfirms(
            pushFlag: "-session-settings-approval-push-approve",
            confirmButton: "Approve change",
            outcome: "approved",
            screenshot: "settings-approval-push-approve-confirm"
        )
    }

    @MainActor
    func testSettingsApprovalPushDeclineConfirmsTheRow() {
        assertSettingsApprovalPushConfirms(
            pushFlag: "-session-settings-approval-push-decline",
            confirmButton: "Decline change",
            outcome: "declined",
            screenshot: "settings-approval-push-decline-confirm"
        )
    }

    @MainActor
    private func assertSettingsApprovalPushConfirms(
        pushFlag: String,
        confirmButton: String,
        outcome: String,
        screenshot: String
    ) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture", "-session-settings-approvals", pushFlag]
        app.launch()
        defer { app.terminate() }
        let decisions = app.staticTexts["fixture.session-settings-decisions"]
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(app.buttons[confirmButton].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "read, bash → read, bash, fetch_page")).firstMatch.exists,
                      app.debugDescription)
        XCTAssertEqual(app.alerts.count, 0)
        keepScreenshot(named: screenshot)
        // The managed child hides its parent probe from accessibility. Cancel
        // first and observe the actual server counter, rather than reading covered UI.
        app.buttons["confirmation-cancel"].tap()
        XCTAssertTrue(waitForLabel(decisions, containing: "decisions:none", timeout: 5), "A pushed decision that was cancelled writes nothing")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 5))
        app.buttons["Stop session"].tap()
        XCTAssertTrue(app.buttons[confirmButton].waitForExistence(timeout: 5))
        app.buttons[confirmButton].tap()
        XCTAssertTrue(waitForLabel(decisions, containing: "\(outcome):settings-session-request", timeout: 5))
        XCTAssertFalse(decisions.label.contains("settings-other-request"),
                       "Another chat's request is never decided from this chat's push")
        XCTAssertTrue(app.descendants(matching: .any)["settings-approvals-header"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testSettingsChangesOpensRequestingChatOnItsOwningMac() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-changes"]
        app.launch(); defer { app.terminate() }
        // The Gateway's first filtered page is empty but not the end: opening
        // Changes still shows the one entry, without tapping Load more.
        let row = app.buttons["settings-change-fixture-change"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["settings-changes-load-more"].exists, "The feed's end needs no Load more")
        keepScreenshot(named: "925-changes-first-page")
        row.tap()
        XCTAssertTrue(app.staticTexts["Key history"].waitForExistence(timeout: 5), app.debugDescription)
        let iso = NSPredicate(format: "label MATCHES %@", ".*[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:.*")
        XCTAssertEqual(app.descendants(matching: .any).matching(iso).count, 0, "Change detail shows readable dates, never raw ISO timestamps")
        keepScreenshot(named: "925-change-detail")
        tapScrolling(app.buttons["Open requesting chat"], in: app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-changes-route"],
                                  containing: "owned:true:fixture-chat", timeout: 5))
    }

    @MainActor
    func testSettingsChangesOpensOwningHomeTask() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-settings-history"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-settings")
        tapScrolling(app.buttons["Changes"].firstMatch, in: app)
        let row = app.buttons["settings-change-worker-setting"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        tapScrolling(app.buttons["Open task"], in: app)
        XCTAssertTrue(app.buttons["home-sheet-done-task"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Settings model: continue epic #758"].waitForExistence(timeout: 5),
                      "Open the audit actor's exact canonical task, not the task list")
    }

    @MainActor
    func testSettingsChangesScopeFiltersAndApprovalReceipts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-changes", "-settings-changes-session", "-settings-changes-scope", "-settings-changes-approvals"]
        app.launch(); defer { app.terminate() }
        let approve = app.buttons["Approve"].firstMatch
        XCTAssertTrue(app.buttons["This session"].waitForExistence(timeout: 5))
        XCTAssertFalse(approve.exists, "Mac approvals do not belong to this Session's chat-layer scope")
        app.buttons["All scopes"].tap()
        XCTAssertTrue(approve.waitForExistence(timeout: 5), app.debugDescription)
        tapScrolling(approve, in: app)
        XCTAssertTrue(app.buttons["confirmation-cancel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["confirmation-cancel"].tap()
        XCTAssertEqual(app.staticTexts["fixture.settings-changes-decisions"].label, "decisions:0 approved:0")
        tapScrolling(approve, in: app)
        app.buttons["Approve change"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-changes-decisions"], containing: "decisions:1 approved:1", timeout: 5))
        let decline = app.buttons["Decline"].firstMatch
        tapScrolling(decline, in: app)
        app.buttons["Decline change"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-changes-decisions"], containing: "decisions:2 approved:1", timeout: 5))
        drainChanges(app)
        XCTAssertTrue(app.buttons["settings-change-project-change"].exists)
        XCTAssertTrue(app.buttons["settings-change-foreign-change"].exists, "All scopes includes other sessions")
        app.buttons["This session"].tap()
        drainChanges(app)
        XCTAssertTrue(app.buttons["settings-change-ui-change"].exists)
        XCTAssertFalse(app.buttons["settings-change-foreign-change"].exists)
        XCTAssertFalse(app.buttons["settings-change-project-change"].exists, "Repository history is not a Session value")
        // Filters intersect with the exact context, never widen its ownership.
        chooseChangesFilter(app, row: "settings-changes-actor", option: "Agents and outside")
        drainChanges(app)
        XCTAssertFalse(app.buttons["settings-change-ui-change"].exists)
        chooseChangesFilter(app, row: "settings-changes-actor", option: "Everyone")
        chooseChangesFilter(app, row: "settings-changes-status", option: "Failed")
        drainChanges(app)
        XCTAssertTrue(app.buttons["settings-change-ui-change"].exists)
        XCTAssertFalse(app.buttons["settings-change-fixture-change"].exists)
        XCTAssertFalse(app.buttons["settings-change-project-change"].exists)
        keepScreenshot(named: "758-changes-scoped-filter-intersection")
    }

    /// Changes follows empty filtered pages on its own and offers Load more only
    /// for further history; follow every offered page so absence is meaningful.
    @MainActor
    private func drainChanges(_ app: XCUIApplication) {
        let more = app.buttons["settings-changes-load-more"]
        for _ in 0..<6 where more.waitForExistence(timeout: 2) { tapScrolling(more, in: app) }
    }

    /// Opens Changes' Filters sheet, picks `option` on one filter row, and returns to the feed.
    @MainActor
    private func chooseChangesFilter(_ app: XCUIApplication, row: String, option: String) {
        let filters = app.buttons["settings-changes-filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5), app.debugDescription)
        filters.tap()
        let control = app.descendants(matching: .any)[row].buttons.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        control.tap()
        let choice = app.buttons["settings-option-\(option)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        XCTAssertTrue(choice.waitForNonExistence(timeout: 5), app.debugDescription)
        closeTopSheet(app) // Filters
    }

    @MainActor
    func testSettingsChangesLastLookUsesPreviousVisit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-changes"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["settings-change-fixture-change"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Since you last looked"].exists)
        keepScreenshot(named: "758-changes-since-last-visit")
    }

    @MainActor
    func testSettingsChangesUndoRefusalRetainsCurrentDiff() {
        continueAfterFailure = false
        for outcomeFailure in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-changes", "-settings-undo-refused"]
            if outcomeFailure { app.launchArguments.append("-settings-undo-outcome-refused") }
            app.launch(); defer { app.terminate() }
            let entry = app.buttons["settings-change-fixture-change"]
            XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
            tapScrolling(entry, in: app)
            tapScrolling(app.buttons["Undo"], in: app)
            app.buttons["Undo change"].tap()
            XCTAssertTrue(app.staticTexts["Current value"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts["8 retries"].exists)
            XCTAssertTrue(app.staticTexts["Value when applied"].exists)
            XCTAssertTrue(app.staticTexts["6 retries"].exists)
            XCTAssertEqual(app.staticTexts["fixture.settings-changes-undos"].label, "undos:1")
            keepScreenshot(named: "758-changes-undo-current-diff-\(outcomeFailure ? "outcome" : "rpc")")
        }
    }

    /// A redacted entry never recorded its values, so its detail offers no Undo (#769).
    @MainActor
    func testSettingsChangesRedactedEntryIsNotUndoable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-changes", "-settings-changes-redacted"]
        app.launch()
        defer { app.terminate() }
        let entry = app.buttons["settings-change-fixture-change"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        tapScrolling(entry, in: app)
        XCTAssertTrue(app.staticTexts["Not undoable"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(showsText("Hidden", in: app))
        XCTAssertFalse(app.buttons["Undo"].exists, "A redacted change must not offer Undo")
        XCTAssertEqual(app.staticTexts["fixture.settings-changes-undos"].label, "undos:0")
        keepScreenshot(named: "769-changes-redacted-not-undoable")
    }

    @MainActor
    func testSettingsChangesFeedOpensKeyHistoryAndUndoesThroughGatewayReceipt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-changes"]
        app.launch()
        defer { app.terminate() }

        // The first filtered page is empty but has a cursor: it is not EOF, and
        // opening Changes follows it without a Load more tap.
        let row = app.buttons["settings-change-fixture-change"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "An empty history page with a cursor is not EOF: \(app.debugDescription)")
        XCTAssertTrue(showsText("6 retries", in: app))
        row.tap()
        XCTAssertTrue(showsText("Key history", in: app))
        XCTAssertTrue(showsText("Risk evaluation", in: app))
        XCTAssertTrue(showsText("The deterministic floor is sufficient.", in: app))
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), app.debugDescription)
        undo.tap()
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["Undo change"].tap()
        XCTAssertTrue(app.staticTexts["Key history"].waitForNonExistence(timeout: 5), "A confirmed receipt dismisses the covered detail")
        XCTAssertTrue(app.staticTexts["fixture.settings-changes-undos"].waitForExistence(timeout: 5))
        XCTAssertTrue(showsText("undos:1", in: app), "Undo was issued exactly once through settings.undo")
    }

    /// The generic renderer over a fixture schema (settings-model.md F1, 7.5): a new
    /// section, subgroup, key and badge kind render from served data alone; an
    /// unknown control is read-only; the Gateway refuses an invalid value inline
    /// and nothing applies; a model without thinking offers no thinking options.
    @MainActor
    func testSettingsRendererRetiresCoveredPreviewWithoutWritingOrLockingRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-renderer-held-preview"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        // The fixture mounts the Context sheet itself, under its own cover control.
        XCTAssertTrue(any["settings-section-context-detail"].waitForExistence(timeout: 10), app.debugDescription)
        let toggle = any["settings-row-context.images.block"].switches.firstMatch
        tapScrolling(toggle, in: app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-held"], containing: "held:1", timeout: 5))
        app.buttons["Cover renderer"].tap()
        app.buttons["Release preview"].tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["fixture.settings-renderer-applied"].label, "applied:0")
        XCTAssertTrue(toggle.isEnabled, "Retiring a disposable preview must release its busy state")
        tapScrolling(toggle, in: app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:1", timeout: 5))
        keepScreenshot(named: "758-retired-preview-rejoined")
    }

    @MainActor
    func testSettingsRendererRendersAFixtureSchema() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let applied = app.staticTexts["fixture.settings-renderer-applied"]
        let thinking = app.staticTexts["fixture.settings-renderer-thinking-options"]
        XCTAssertTrue(app.buttons["settings-section-model-open"].waitForExistence(timeout: 10), app.debugDescription)
        // Settings: one row per section, every key on its section's sheet.
        XCTAssertFalse(any["settings-row-model.ref"].exists, "Keys live on section sheets")
        XCTAssertFalse(app.buttons["Show all"].exists, "Settings never expands in place")
        XCTAssertTrue(app.buttons["settings-section-lab-open"].exists, "A section the app never heard of renders from its served title")
        keepScreenshot(named: "settings-renderer-primary")

        openRendererSection(app, "run")
        XCTAssertTrue(any["settings-row-run.transport"].exists)
        XCTAssertTrue(showsText("How many times a failed request is retried", in: app), "Section rows carry source and help")
        keepScreenshot(named: "settings-renderer-run-sheet")
        closeTopSheet(app)

        // An invalid value: the Gateway's dry run refuses it under the row; nothing applies.
        openRendererSection(app, "lab")
        let invalid = any["settings-row-lab.invalidValue"]
        scrollTo(invalid, in: app)
        let field = invalid.textFields.firstMatch
        tapScrolling(field, in: app)
        field.tap()
        field.typeText("rejected\n")
        XCTAssertTrue(any["settings-row-lab.invalidValue-error"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture value rejected")).firstMatch.exists)
        XCTAssertTrue(waitForLabel(applied, containing: "applied:0", timeout: 2))
        keepScreenshot(named: "settings-renderer-invalid")
        // The new subgroup, the unknown badge, the unknown control and the read-only secret.
        XCTAssertTrue(showsText("Experiments", in: app), "A subgroup the app never heard of")
        tapScrolling(app.buttons["settings-row-lab.focusMode-source"], in: app)
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForExistence(timeout: 5))
        XCTAssertTrue(showsText("New", in: app), "Unknown evidence remains inspectable in Value & Source")
        closeTopSheet(app)
        scrollTo(any["settings-row-lab.palette"], in: app)
        XCTAssertTrue(showsText("Teal", in: app), "An unknown control shows its display read-only")
        scrollTo(any["settings-row-lab.secretToken"], in: app)
        XCTAssertTrue(showsText("Update Tron to edit", in: app))
        keepScreenshot(named: "settings-renderer-lab-sheet")
        closeTopSheet(app)

        // The row's trailing value opens the catalog picker.
        openRendererSection(app, "model")
        let modelCatalogRow = settingEditor(any["settings-row-model.ref"])
        tapScrolling(modelCatalogRow, in: app)
        let lite = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Lite")).firstMatch
        XCTAssertTrue(lite.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "settings-renderer-catalog")
        XCTAssertTrue(app.images["Selected"].exists, "The catalog marks the current value like the existing pickers")
        closeTopSheet(app)
        XCTAssertTrue(waitForLabel(applied, containing: "applied:0", timeout: 2), "Opening and dismissing the catalog must not write settings")
        tapScrolling(modelCatalogRow, in: app)
        XCTAssertTrue(lite.waitForExistence(timeout: 5), app.debugDescription)
        lite.tap()
        // Switching to a model without thinking: the options are asked for again, and there are none.
        XCTAssertTrue(waitForLabel(applied, containing: "applied:1", timeout: 5))
        XCTAssertTrue(waitForLabel(thinking, containing: "thinking-options:0", timeout: 5))
        XCTAssertTrue(any["settings-row-model.thinking"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Off")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Settings' tools.active editor reuses Available Tools grouping and tool detail.
    @MainActor
    func testSettingsToolsEditorUsesAvailableToolsListAndDetails() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture"]
        app.launch()
        defer { app.terminate() }
        let toolsSection = app.buttons["settings-section-tools-open"]
        XCTAssertTrue(toolsSection.waitForExistence(timeout: 10), app.debugDescription)
        tapScrolling(toolsSection, in: app)
        let toolsRow = app.descendants(matching: .any)["settings-row-tools.active"]
        XCTAssertTrue(toolsRow.waitForExistence(timeout: 5), app.debugDescription)
        tapScrolling(settingEditor(toolsRow), in: app)
        let any = app.descendants(matching: .any)
        let count = any.matching(NSPredicate(format: "label == %@", "2 of 2 on")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(any.matching(NSPredicate(format: "label == %@", "Read")).firstMatch.exists, app.debugDescription)
        keepScreenshot(named: "900-tools-list-light")
        let detailButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read, Read file contents")).firstMatch
        tapScrolling(detailButton, in: app)
        XCTAssertTrue(app.staticTexts["Fixture path input"].waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "900-tools-detail-light")
        closeTopSheet(app)
        // A chosen tool the catalog no longer offers stays listed with its reason, so it can be cleared.
        XCTAssertTrue(app.staticTexts["Not available here"].exists, app.debugDescription)
        // Toggles edit a draft like every checklist; Save applies one change.
        let applied = app.staticTexts["fixture.settings-renderer-applied"]
        let read = app.switches["Read"]
        XCTAssertTrue(read.waitForExistence(timeout: 5), app.debugDescription)
        read.tap()
        tapScrolling(app.switches["Retired"], in: app)
        XCTAssertTrue(any.matching(NSPredicate(format: "label == %@", "0 of 2 on")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(applied.label, "applied:0", "Toggling edits the draft; nothing applies before Save")
        app.buttons["tron-sheet-save"].tap()
        XCTAssertTrue(waitForLabel(applied, containing: "applied:1", timeout: 5))
    }

    /// Sheet intro text renders at the settings row subtitle's size and text style
    /// (#900): at a large type size each wrapped intro line is one row-subtitle line.
    @MainActor
    func testSheetIntroTextMatchesRowSubtitleSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch()
        defer { app.terminate() }
        // A one-line row subtitle at this size is the unit the intro is measured in.
        let subtitle = app.staticTexts["Your own model definitions"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10), app.debugDescription)
        let line = subtitle.frame.height
        XCTAssertGreaterThan(line, 8)
        tapScrolling(app.buttons["Changes"].firstMatch, in: app)
        let intro = app.staticTexts["Settings agents changed, and edits made outside Tron. Open one to see it in full or undo it."]
        XCTAssertTrue(intro.waitForExistence(timeout: 5), app.debugDescription)
        // A medium-detent sheet is drawn slightly scaled; measure at large, settled.
        app.staticTexts["Changes"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        var frame = intro.frame
        for _ in 0..<10 {
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.3)
            if intro.frame == frame { break }
            frame = intro.frame
        }
        keepScreenshot(named: "900-changes-intro")
        let lines = (frame.height / line).rounded()
        XCTAssertGreaterThanOrEqual(lines, 1)
        XCTAssertEqual(frame.height, lines * line, accuracy: 0.5,
                       "The intro uses the row subtitle's size: \(frame.height) is not \(lines) lines of \(line)")
    }

    /// Opens one section's sheet from Settings.
    @MainActor
    private func openRendererSection(_ app: XCUIApplication, _ id: String) {
        tapScrolling(app.buttons["settings-section-\(id)-open"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings-section-\(id)-detail"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Dismisses the frontmost sheet by its own Done; covered sheets' Done
    /// buttons are not hittable.
    @MainActor
    private func closeTopSheet(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(done, app.debugDescription)
        done?.tap()
    }

    /// Source actions are renderer primitives, not per-key code. The fixture
    /// socket receives one unset via the existing dry-run/receipt path; unknown
    /// actions stay display-only rather than dispatching arbitrary operations.
    @MainActor
    func testSettingsRendererUsesCurrentDefaultSourceAction() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-renderer-source-actions"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["settings-section-model-open"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings-row-model.ref-open"].exists, "No per-key intermediate sheet")
        openRendererSection(app, "model")
        let reset = app.buttons["settings-row-model.ref-reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5), app.debugDescription)
        assertCircularRevert(reset)
        XCTAssertFalse(app.buttons["Unsupported action"].exists)
        keepScreenshot(named: "settings-current-default-before")
        tapScrolling(reset, in: app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:1", timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Fixture Lite")).firstMatch
            .waitForExistence(timeout: 5), "The reset value reads back on the key's row")
        XCTAssertFalse(app.staticTexts["Value & Source"].exists, "Reset must not also inspect the row")
        app.buttons["settings-row-model.ref-source"].tap()
        XCTAssertTrue(app.staticTexts["Value & Source"].waitForExistence(timeout: 5))
        XCTAssertTrue(showsText("Future source", in: app), "Unknown source evidence is retained in the one provenance destination")
        XCTAssertFalse(app.buttons["Unsupported action"].exists, "Unknown evidence must not become an arbitrary command")
        keepScreenshot(named: "settings-current-default-after")
    }

    /// A served catalog remains complete beyond its first page, and browsing it
    /// never changes the setting.
    @MainActor
    func testSettingsRendererCatalogPagesWithoutWriting() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        openRendererSection(app, "model")
        tapScrolling(settingEditor(any["settings-row-model.ref"]), in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Pro")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(any["settings-option-Fixture Page Two"].exists)
        let more = app.buttons["settings-catalog-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "A served nextCursor must make the rest of the catalog reachable")
        more.tap()
        XCTAssertTrue(any["settings-option-Fixture Page Two"].waitForExistence(timeout: 5))
        XCTAssertFalse(more.exists, "The final page retires its cursor")
        keepScreenshot(named: "settings-catalog-second-page")
        closeTopSheet(app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:0", timeout: 5))
    }

    /// The same native anchored choice editor works for schema-only choices,
    /// without thinking-specific labels or a second slider presentation owner.
    @MainActor
    func testSettingsRendererOrderedChoiceUsesSharedSlider() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        openRendererSection(app, "model")
        let row = any["settings-row-model.thinking"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        keepScreenshot(named: "settings-renderer-ordered-choice-row")
        tapScrolling(settingEditor(row), in: app)
        let slider = any["settings-choice-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "An ordered choice reuses the native anchored slider, not a menu")
        keepScreenshot(named: "settings-renderer-ordered-choice-expanded")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        // The editor's modal ScrollView becomes firstMatch while it is open.
        // Dismiss on the host backdrop below the observed slider, not inside that panel.
        let outside = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 10, dy: min(app.frame.maxY - 70, slider.frame.maxY + 80)))
        outside.tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:1", timeout: 5))
        // The row itself reads back the chosen value.
        XCTAssertTrue(row.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value == %@", "Off", "Off"))
            .firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    /// A schema number uses the same anchored slider interaction and saves its
    /// bounded numeric value through the fixture Gateway.
    @MainActor
    func testSettingsRendererNumberUsesSharedSlider() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        openRendererSection(app, "run")
        let row = any["settings-row-run.retry.maxRetries"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        keepScreenshot(named: "settings-renderer-number-row")
        tapScrolling(settingEditor(row), in: app)
        let slider = any["settings-number-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "A schema number uses the shared bounded slider")
        keepScreenshot(named: "settings-renderer-number-expanded")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:0", timeout: 2),
                      "Opening the editor must not write an override")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5)).tap()
        let outside = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 10, dy: min(app.frame.maxY - 70, slider.frame.maxY + 80)))
        outside.tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:1", timeout: 5))
        let numberButton = any["settings-row-run.retry.maxRetries"].buttons.matching(identifier: "settings-number-control").firstMatch
        XCTAssertEqual(numberButton.value as? String, "10 retries",
                       "The served dynamic range wins over the static 0–100 declaration")
        keepScreenshot(named: "settings-renderer-number-persisted")
        // The advanced key is in the same sheet's Advanced group.
        let future = any["settings-row-run.futureNumber"]
        scrollTo(future, in: app)
        XCTAssertTrue(future.staticTexts["Future numeric value"].exists)
        XCTAssertFalse(future.buttons["settings-number-control"].exists,
                       "An out-of-representation range must stay visible read-only, never trap")
        keepScreenshot(named: "settings-renderer-number-unsupported")
    }

    /// Write-only replacement and ordered-list operations cross the real client
    /// socket; reopening reads the stored result rather than the editor's draft.
    @MainActor
    func testSettingsRendererSecretAndListEditors() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        openRendererSection(app, "lab")
        let password = any["settings-row-lab.password"]
        reveal(password, in: app)
        tapScrolling(settingEditor(password), in: app)
        let field = app.secureTextFields["New value"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        expandSettingsSheet(app, title: "Password")
        keepScreenshot(named: "settings-renderer-secret-empty")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The real secure field must gain keyboard focus before typing")
        field.typeText("fixture-replacement")
        app.buttons["Save"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:1", timeout: 5))
        XCTAssertFalse(showsText("fixture-replacement", in: app), "A submitted secret never appears in the row")
        tapScrolling(settingEditor(password), in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "New value", "Reopening never pre-fills a secret")
        closeTopSheet(app)

        let paths = any["settings-row-lab.paths"]
        tapScrolling(settingEditor(paths), in: app)
        XCTAssertTrue(app.buttons["Remove alpha"].waitForExistence(timeout: 5))
        expandSettingsSheet(app, title: "Paths")
        keepScreenshot(named: "settings-renderer-list-before-edit")
        // Direct row actions work at any sheet depth (#877).
        app.buttons["Remove alpha"].tap()
        app.textFields["Value"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.textFields["Value"].typeText("gamma")
        app.buttons["Add"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:2", timeout: 5))
        XCTAssertTrue(paths.buttons.matching(NSPredicate(format: "value == %@", "beta, gamma")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        tapScrolling(settingEditor(paths), in: app)
        XCTAssertTrue(app.buttons["Remove gamma"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove alpha"].exists)
        keepScreenshot(named: "settings-renderer-list-persisted")
        closeTopSheet(app)

        // A numeric map uses only field names and bounds served by this unknown
        // fixture schema. Saving preserves untouched fields; Done never writes.
        let weights = any["settings-row-lab.weights"]
        tapScrolling(settingEditor(weights), in: app)
        // The canonical settings row combines its label for accessibility;
        // target that semantic row's field rather than a nonexistent field label.
        let blue = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Blue weight")).textFields.firstMatch
        let red = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Red weight")).textFields.firstMatch
        XCTAssertTrue(blue.waitForExistence(timeout: 5), app.debugDescription)
        expandSettingsSheet(app, title: "Weights")
        blue.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        blue.typeText("101\n")
        XCTAssertFalse(app.buttons["Save"].isEnabled, "The served range must constrain representation")
        // The value is trailing-aligned: tap its end so deletes remove it.
        blue.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        blue.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "9\n")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:3", timeout: 5))
        tapScrolling(settingEditor(weights), in: app)
        XCTAssertEqual(red.value as? String, "2")
        XCTAssertEqual(blue.value as? String, "9")
        expandSettingsSheet(app, title: "Weights")
        blue.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        blue.typeText(XCUIKeyboardKey.delete.rawValue + "7\n")
        closeTopSheet(app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:3", timeout: 5))
        tapScrolling(settingEditor(weights), in: app)
        XCTAssertEqual(blue.value as? String, "9", "Dismissed draft must not replace the saved numeric map")
        keepScreenshot(named: "settings-renderer-number-map")
    }

    /// The renderer in dark mode at the largest accessibility text size.
    @MainActor
    func testSettingsRendererDarkLargeType() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-renderer-dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.buttons["settings-section-model-open"].waitForExistence(timeout: 10), app.debugDescription)
        keepScreenshot(named: "settings-renderer-dark-xxxl-primary")
        openRendererSection(app, "run")
        scrollTo(any["settings-row-run.retry.maxRetries"], in: app)
        XCTAssertTrue(any["settings-row-run.retry.maxRetries"].isHittable, "Section rows stay reachable at XXXL")
        let transport = any["settings-row-run.transport"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(transport, in: app)
        keepScreenshot(named: "settings-renderer-dark-xxxl-run-sheet")
    }

    /// Any element whose label contains the text: a settings row combines its labels.
    @MainActor
    private func showsText(_ text: String, in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }

    /// Scrolls a lazy list down until the element is built and hittable.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// A competing control stacks below its title but keeps the row's trailing inset.
    @MainActor
    private func assertStacked(_ control: XCUIElement, below title: XCUIElement, in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(title.exists && control.exists, app.debugDescription, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.minY, title.frame.maxY,
                                    "\(control.label) sits below \(title.label), not beside it", file: file, line: line)
        // Manage Session owns an 18pt content inset; the shared row adds 14pt.
        XCTAssertEqual(control.frame.maxX, app.windows.firstMatch.frame.maxX - 32, accuracy: 1,
                       "\(control.label) retains its container + standard row trailing inset", file: file, line: line)
    }

    /// Scrolls until the element is hittable.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
    }

    @MainActor
    func testIntegrationDestinationsHaveOneDoneButtonThroughSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-navigation-fixture"]
        for title in ["Connected Services", "MCP Servers"] {
            app.launch()
            let destination = app.buttons[title]
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            for _ in 0..<8 where !destination.isHittable { app.swipeUp() }
            XCTAssertTrue(destination.isHittable)
            destination.tap()
            let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
            XCTAssertTrue(done.firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(done.allElementsBoundByIndex.filter(\.isHittable).count, 1,
                           "Only the progressive settings shell owns dismissal")
            keepScreenshot(named: "settings-\(title)-single-done-light")
            done.allElementsBoundByIndex.first(where: \.isHittable)?.tap()
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    /// The reported three-window quota must wrap without creating a second action row.
    @MainActor
    func testProviderUsageWrapsWithoutStackingDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-ui-providers"]
        app.launch(); defer { app.terminate() }
        let two = app.buttons["Details for OpenAI Codex"], three = app.buttons["Details for Opencode Go"]
        XCTAssertTrue(three.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((three.value as? String ?? "").contains("100% used (Monthly)"))
        XCTAssertLessThan(three.frame.height, two.frame.height * 1.7,
                          "A third usage window wraps in the label column, not into a second Details row")
        XCTAssertEqual(three.frame.minX, two.frame.minX, accuracy: 1)
        XCTAssertEqual(three.frame.maxX, two.frame.maxX, accuracy: 1)
        keepScreenshot(named: "1261-provider-wrap-regression")
    }

    @MainActor
    func testDefaultToolsMovesToToolsAndPreservesUnmanagedSelectors() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-ui-tools-write"]
        app.launch(); defer { app.terminate() }
        tapScrolling(app.buttons["settings-link-Extensions"], in: app)
        XCTAssertTrue(app.staticTexts["Built-in Extensions"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Default Tools"].exists)
        XCTAssertFalse(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Always include codemode")).firstMatch.exists)
        closeTopSheet(app)
        tapScrolling(app.buttons["settings-section-tools-open"], in: app)
        XCTAssertTrue(app.staticTexts["Default Tools"].waitForExistence(timeout: 5))
        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Always include codemode")).firstMatch
        tapScrolling(toggle, in: app)
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.tools-write"], containing: "mac@mac=read,retired,+codemode", timeout: 5),
                      "The relocated control writes only its own layer and preserves unknown selectors")
        XCTAssertEqual(app.staticTexts["fixture.settings-renderer-applied"].label, "applied:1")
        closeTopSheet(app)
        tapScrolling(app.buttons["settings-section-tools-open"], in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["Other entries"].exists)
        keepScreenshot(named: "1261-tools-persisted-selectors")
    }

    @MainActor
    func testPushReadinessAndRegistrationAreSeparateFromPolicyToggles() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-ui-push"]
        app.launch(); defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let summary = any["push-registration-summary"], policy = any["push-alert-policy"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(policy.exists)
        XCTAssertLessThan(summary.frame.maxY, policy.frame.minY)
        XCTAssertEqual(summary.switches.count, 0)
        XCTAssertEqual(policy.switches.count, 3)
        XCTAssertTrue(summary.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Complete")).firstMatch.exists)
        keepScreenshot(named: "1261-push-separate-summary")
    }

    @MainActor
    func testRendererConfirmationSurvivesCoverageAndCancelDoesNotWrite() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-renderer-fixture", "-settings-renderer-confirm"]
        app.launch(); defer { app.terminate() }
        let toggle = app.descendants(matching: .any)["settings-row-context.images.block"].switches.firstMatch
        tapScrolling(toggle, in: app)
        let confirm = app.buttons["Change setting"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.staticTexts["fixture.settings-renderer-applied"].label, "applied:0")
        app.buttons["confirmation-cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture.settings-renderer-applied"].label, "applied:0")
        tapScrolling(toggle, in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.settings-renderer-applied"], containing: "applied:1", timeout: 5))
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(toggle.exists && toggle.isEnabled, "Only the confirmation closes, not its settings parent")
        keepScreenshot(named: "1261-renderer-confirmed-once")
    }

    @MainActor
    func testSharedRenameValidatesClearsAndCommitsTheEnteredName() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-configuration-fixture"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Stop session"].waitForExistence(timeout: 10))
        app.buttons["Stop session"].tap()
        let rename = app.buttons["manage-session-rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.tap()
        let save = app.buttons["confirmation-primary-toolbar"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["Clear text"].tap()
        XCTAssertFalse(save.isEnabled)
        let field = app.textFields.firstMatch
        field.tap(); field.typeText("A renamed session")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        rename.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "A renamed session")
        app.buttons["confirmation-cancel"].tap()
        keepScreenshot(named: "1261-rename-committed")
    }

    @MainActor
    func testUIFixesVisualReviewCaptures() {
        continueAfterFailure = false
        for surface in ["providers", "push", "placement", "confirmation-light", "confirmation-dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture"]
            if surface.hasPrefix("confirmation") {
                app.launchArguments += ["-settings-changes", "-settings-changes-approvals", "-settings-nested"]
                if surface.hasSuffix("dark") { app.launchArguments.append("-settings-renderer-dark") }
            } else if surface != "placement" { app.launchArguments.append("-settings-ui-\(surface)") }
            app.launch()
            XCTAssertTrue(app.staticTexts["fixture.settings-renderer-applied"].waitForExistence(timeout: 10), app.debugDescription)
            if surface.hasPrefix("confirmation") {
                tapScrolling(app.buttons["Approve"].firstMatch, in: app)
                XCTAssertTrue(app.buttons["Approve change"].waitForExistence(timeout: 5), app.debugDescription)
                keepScreenshot(named: "1261-\(surface)")
                let cancel = app.buttons["confirmation-cancel"]
                if cancel.exists {
                    cancel.tap()
                    app.buttons["Decline"].firstMatch.tap()
                    XCTAssertTrue(app.buttons["Decline change"].waitForExistence(timeout: 5))
                    keepScreenshot(named: "1261-decline-\(surface)")
                }
            } else if surface == "placement" {
                tapScrolling(app.buttons["settings-link-Extensions"], in: app)
                XCTAssertTrue(app.staticTexts["Built-in Extensions"].waitForExistence(timeout: 5), app.debugDescription)
                keepScreenshot(named: "1261-extensions")
                app.staticTexts.matching(identifier: "Extensions").allElementsBoundByIndex.last!
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
                let defaultTools = app.staticTexts["Default Tools"]
                if defaultTools.exists {
                    let lastControl = app.buttons["Other tools with codemode"]
                    for _ in 0..<5 where !lastControl.isHittable { app.swipeUp() }
                    keepScreenshot(named: "1261-extensions-default-tools")
                } else {
                    keepScreenshot(named: "1261-extensions-large")
                }
                closeTopSheet(app)
                tapScrolling(app.buttons["settings-section-tools-open"], in: app)
                XCTAssertTrue(app.descendants(matching: .any)["settings-section-tools-detail"].waitForExistence(timeout: 5), app.debugDescription)
                keepScreenshot(named: "1261-tools")
                app.staticTexts.matching(identifier: "Tools").allElementsBoundByIndex.last!
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
                keepScreenshot(named: "1261-tools-large")
            } else {
                keepScreenshot(named: "1261-\(surface)")
            }
            app.terminate()
        }
    }

    @MainActor
    func testMacSettingsUsesSchemaGroupsAndSharedThinkingEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-mac-settings-fixture"]
        app.launch()
        defer { app.terminate() }
        // Settings is one row per section; Thinking is on the Model sheet.
        tapScrolling(app.buttons["settings-section-model-open"], in: app)
        let thinking = app.descendants(matching: .any)["settings-row-model.thinking"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5), app.debugDescription)
        tapScrolling(settingEditor(thinking), in: app)
        let slider = app.descendants(matching: .any)["settings-choice-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        keepScreenshot(named: "mac-settings-schema-thinking")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 10, dy: min(app.frame.maxY - 70, slider.frame.maxY + 80))).tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["fixture.settings-renderer-applied"].label, "applied:0")
        XCTAssertFalse(app.buttons["Settings Scope"].exists)
        closeTopSheet(app) // Model
        assertSettingsTopLevelOrder(app)
    }

    /// Settings top level (#956, #1030): Accounts opens with Connections, This
    /// iPhone holds Push Notifications, Appearance and Sessions, and the last
    /// group, Tools & Diagnostics, holds Mac Terminal, Experimental, Setup and
    /// Logs. Each moved row still opens its own sheet from the shared rows.
    @MainActor
    private func assertSettingsTopLevelOrder(_ app: XCUIApplication) {
        let accounts = app.staticTexts["Accounts"].firstMatch
        for _ in 0..<12 where !accounts.isHittable { app.swipeDown() }
        let connections = app.buttons["settings-link-Connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["settings-link-Custom Models"].exists, "Custom Models belongs in Providers only")
        let accountRows = ["Connections", "Model Providers", "Connected Services"]
            .map { app.buttons["settings-link-\($0)"] }
        let accountTops = [accounts.frame.minY] + accountRows.map(\.frame.minY)
        XCTAssertEqual(accountTops, accountTops.sorted(), "Accounts lists Connections first: \(accountTops)")
        keepScreenshot(named: "settings-top-level-1")

        let iphone = app.staticTexts["This iPhone"].firstMatch
        let diagnostics = app.staticTexts["Tools & Diagnostics"].firstMatch
        let iphoneRows = ["Push Notifications", "Appearance", "Sessions"].map { app.buttons["settings-link-\($0)"] }
        let movedNames = ["Mac Terminal", "Experimental", "Setup", "Logs"]
        let movedRows = movedNames.map { app.buttons["settings-link-\($0)"] }
        for _ in 0..<12 where !movedRows.last!.isHittable { app.swipeUp() }
        keepScreenshot(named: "settings-top-level-2")
        XCTAssertTrue(iphone.isHittable && diagnostics.isHittable, app.debugDescription)
        // Card order, then row order inside each card: no moved row is left in
        // Accounts or This iPhone, and nothing follows Tools & Diagnostics.
        let tops = [iphone.frame.minY] + iphoneRows.map(\.frame.minY) + [diagnostics.frame.minY] + movedRows.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(),
                       "This iPhone (Push Notifications, Appearance, Sessions), then Tools & Diagnostics (Mac Terminal, Experimental, Setup, Logs): \(tops)")
        for group in ["Accounts", "Agent", "Tools & Extensions", "More"] where app.staticTexts[group].firstMatch.exists {
            XCTAssertLessThan(app.staticTexts[group].firstMatch.frame.minY, iphone.frame.minY, "This iPhone follows \(group)")
        }
        // Same shared row inside the same shared group card: every moved row has
        // the Accounts rows' left edge and width, and keeps its scope summary.
        let rowGeometry = connections.frame
        for (row, name) in zip(movedRows, movedNames) {
            XCTAssertEqual(row.frame.minX, rowGeometry.minX, accuracy: 1, "\(name) is a shared Settings row")
            XCTAssertEqual(row.frame.width, rowGeometry.width, accuracy: 1, "\(name) is a shared Settings row")
        }
        for summary in ["A shell on your Mac, even without the Gateway", "Prototypes to try on this iPhone",
                        "Import, Mac session folder, and telemetry", "Diagnostics from this iPhone and your Macs"] {
            XCTAssertTrue(app.staticTexts[summary].exists, "a moved row keeps its scope summary: \(summary)")
        }
        XCTAssertFalse(app.staticTexts["Data & Diagnostics"].exists)
        XCTAssertFalse(app.staticTexts["Stored on this iPhone. Never changes what the agent does."].exists,
                       "Setup and Logs reach the Mac, so neither group makes a device-only promise")

        // Each moved row still opens its own destination.
        let destinations: [(String, XCUIElement)] = [
            ("Mac Terminal", app.descendants(matching: .any)["terminal-sheet-title"].firstMatch),
            ("Experimental", app.descendants(matching: .any)["settings-experimental-swift-apps"].firstMatch),
            ("Setup", app.staticTexts["Import"].firstMatch),
            ("Logs", app.staticTexts["Logs"].firstMatch),
        ]
        for (name, marker) in destinations {
            tapScrolling(app.buttons["settings-link-\(name)"], in: app)
            XCTAssertTrue(marker.waitForExistence(timeout: 10), "\(name) opens its sheet: \(app.debugDescription)")
            keepScreenshot(named: "settings-tools-diagnostics-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
            closeTopSheet(app)
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testKnowledgeSettingsSubmenuStaysOpenDuringParentUpdates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-dashboard-menu-fixture"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Begin updates"].tap()
        app.buttons["dashboard.menu"].tap()
        app.buttons["Knowledge settings"].tap()
        let configuration = app.buttons["Observation configuration"]
        XCTAssertTrue(configuration.waitForExistence(timeout: 3))
        // The fixture performs thirty controlled parent updates. Wait for its
        // completion while the actual tapped submenu remains presented.
        let finished = NSPredicate(format: "label == %@", "Revision 30")
        let updates = expectation(for: finished, evaluatedWith: app.staticTexts["menu-fixture-revision"])
        wait(for: [updates], timeout: 10)
        XCTAssertTrue(configuration.isHittable, "Parent updates must not dismiss the native submenu")
        XCTAssertTrue(app.buttons["Connectors"].exists)
        XCTAssertTrue(app.buttons["Import legacy records"].exists)
        keepScreenshot(named: "knowledge-settings-submenu-after-updates")
        configuration.tap()
        XCTAssertTrue(app.staticTexts["menu-fixture-selection"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testOnboardingPreservesPagedSheetAndPairingJourney() {
        let app = launchResetApp()
        let title = app.staticTexts["Welcome to Tron"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists)
        XCTAssertTrue(app.staticTexts["Pair this iPhone with the Mac running Tron."].exists)
        let pageIndicator = app.descendants(matching: .any)["Onboarding step 1 of 9"]
        XCTAssertTrue(pageIndicator.exists)
        let next = app.buttons["Next"]
        XCTAssertTrue(next.exists, "The welcome toolbar exposes the paged Next action")
        XCTAssertGreaterThanOrEqual(next.frame.height, 34, "The Next capsule retains a usable native toolbar control height")
        let nextLabel = next.staticTexts["Next"]
        XCTAssertTrue(nextLabel.exists, "The Next toolbar label remains accessible")
        let chevron = next.images["chevron.right"]
        XCTAssertTrue(chevron.exists, "The accessible Next action retains its trailing right chevron")
        XCTAssertGreaterThan(chevron.frame.midX, nextLabel.frame.midX,
                             "The chevron follows the Next text, rather than preceding it")
        XCTAssertLessThan(abs(title.frame.midX - app.frame.midX), 18)
        XCTAssertLessThan(abs(title.frame.midY - next.frame.midY), 20)
        XCTAssertGreaterThan(title.frame.minY, app.frame.height * 0.45)
        assertWelcomeVisualParity()
        keepScreenshot(named: "onboarding-welcome-medium-current")

        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Install Tailscale"].waitForExistence(timeout: 2))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Install Tron on Mac"].waitForExistence(timeout: 2))
        app.buttons["Next"].tap()

        XCTAssertTrue(app.staticTexts["Connect a Mac"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Scan QR code"].exists)
        XCTAssertTrue(app.buttons["Enter Manually"].exists)
        app.buttons["Enter Manually"].tap()
        XCTAssertTrue(app.textFields["Tailscale host"].exists)
        XCTAssertTrue(app.textFields["Port"].exists)
        XCTAssertTrue(app.secureTextFields["One-time code"].exists)
        let connect = app.buttons["Connect to Mac"]
        XCTAssertFalse(connect.isEnabled)
        XCTAssertGreaterThanOrEqual(connect.frame.width, 72, "Connect must retain default iOS toolbar horizontal insets")
        XCTAssertGreaterThanOrEqual(connect.frame.height, 35, "Connect must retain default iOS toolbar control height")
        keepScreenshot(named: "onboarding-pairing-large-current")
        assertAccessibilityAuditPasses(app)
    }

    @MainActor
    func testOnboardingPairingPassesAccessibilityAuditInLightMode() {
        let app = launchResetApp(extraArguments: ["-appearanceMode", "light"])
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Enter Manually"].tap()
        XCTAssertTrue(app.secureTextFields["One-time code"].waitForExistence(timeout: 3))
        assertAccessibilityAuditPasses(app)
    }

    @MainActor
    func testPairingValidationIsAccessibleAndDoesNotLeaveOnboarding() {
        let app = launchResetApp()
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Enter Manually"].tap()

        let host = app.textFields["Tailscale host"]
        let code = app.secureTextFields["One-time code"]
        host.tap(); host.typeText("not a host/path")
        code.tap(); code.typeText("NOTREAL1")
        if app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        else { app.tap() }
        app.buttons["Connect to Mac"].tap()

        let notice = app.staticTexts["in-app-notice-card"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(notice.label.contains("Enter a valid host, port, and one-time code."),
                      "Invalid pairing input is announced in an accessible in-app notice")
        XCTAssertTrue(app.staticTexts["Connect a Mac"].exists, "Validation keeps the user on the pairing step")
        XCTAssertTrue(host.exists, "Validation keeps the host field available for correction")
        XCTAssertTrue(app.textFields["Port"].exists, "Validation keeps the port field available for correction")
        XCTAssertTrue(code.exists, "Validation keeps the one-time code field available for correction")
    }

    @MainActor
    func testPairingFieldsScaleAtAccessibilityXXXL() {
        let app = launchResetApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Manual Entry"].tap()

        let host = app.textFields["Tailscale host"]
        XCTAssertTrue(host.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(host.frame.height, 52, "The custom host field must grow at accessibility XXXL")
        XCTAssertTrue(app.textFields["Port"].exists)
        let code = app.secureTextFields["One-time code"]
        if !code.exists { app.swipeUp() }
        XCTAssertTrue(code.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(code.frame.height, 40, "The inner UIKit secure field must scale at accessibility XXXL")
    }

    @MainActor
    func testOnboardingSheetSupportsNativeExpansionGesture() {
        let app = launchResetApp()
        let title = app.staticTexts["Welcome to Tron"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let initialY = title.frame.minY
        app.swipeUp()
        let expanded = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return element.frame.minY < initialY - 80
        }
        expectation(for: expanded, evaluatedWith: title)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testAskUserAllowCancelCancelSendsExactlyOneScopedCancellation() {
        let app = launchAskUser(multiple: true)
        waitForAskUserForm(in: app)
        let cancel = app.buttons["Cancel form"]
        let send = app.buttons["Submit all answers"]
        XCTAssertTrue(cancel.exists && send.exists)
        XCTAssertLessThan(cancel.frame.maxX, app.frame.midX)
        XCTAssertGreaterThan(send.frame.minX, app.frame.midX)
        keepScreenshot(named: "ask-user-cancel-left-send-right")
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=true scope=ask-user-interaction/hosted-ask-user-epoch/1"].exists)
        XCTAssertFalse(app.staticTexts["Mutation count: 2"].exists)
        let cancelled = app.staticTexts["Cancelled — no answers submitted"].firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["This question was cancelled."].exists)
        XCTAssertFalse(app.staticTexts["No answers submitted"].exists)
        let progress = app.staticTexts["1/2"]
        XCTAssertTrue(progress.exists)
        XCTAssertLessThan(abs(cancelled.frame.midY - progress.frame.midY), 8)
        keepScreenshot(named: "ask-user-cancelled-single-status-row")
    }

    @MainActor
    func testExtensionWidgetsSheetRendersRetainedContent() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-extension-widgets-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Extension widgets fixture"].waitForExistence(timeout: 10), app.debugDescription)
        let sheet = app.otherElements["session-activity-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        // Producer attribution for both retained kinds.
        XCTAssertTrue(app.staticTexts["Goal"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["npm:fixture-extension"].exists)
        // String widget lines render as native text.
        XCTAssertTrue(app.staticTexts["Goal active"].exists)
        XCTAssertTrue(app.staticTexts["Used 12k tokens"].exists)
        // A retained status is presentable on its own, which is the only content a
        // paused goal leaves behind after it clears its widget.
        XCTAssertTrue(app.staticTexts["Goal paused (/goal resume)"].exists)
        // An ownerless status is grouped, never dropped.
        XCTAssertTrue(app.staticTexts["Unknown extension"].exists)
        // A retained read-only component frame renders its sanitized content.
        let frameText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Frame progress 3 of 5")
        ).firstMatch
        XCTAssertTrue(frameText.waitForExistence(timeout: 3), app.debugDescription)
        // Admitted-but-unpresentable content is disclosed, not silently dropped.
        XCTAssertTrue(app.staticTexts["Some extension content is not shown on this device yet."].exists)
        keepScreenshot(named: "extension-widgets-sheet-content")
        app.buttons["Done"].tap()
        XCTAssertFalse(sheet.waitForExistence(timeout: 2))
    }

    /// Failure modes: attributed sections are dropped or reordered, the overview
    /// leaks section entries, the overview or a section sheet opens beyond its
    /// medium detent, a section sheet omits its purpose or attributed sources,
    /// or an instruction file cannot be read in full.
    @MainActor
    func testAgentInstructionsSectionsOpenSheetsWithTheirSources() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-agent-instructions-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let order = ["preamble", "tools", "rules", "docs", "project_context", "skills", "cwd", "tron"]
        let headers = order.map { app.buttons["agent-instructions-section-\($0)"] }
        XCTAssertTrue(headers[0].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(headers.allSatisfy(\.exists), app.debugDescription)
        XCTAssertEqual(headers.map(\.frame.minY), headers.map(\.frame.minY).sorted(), "Sections must keep the model's reading order")
        XCTAssertTrue(headers[7].label.contains("Each turn"), "The per-turn Tron context must be marked: \(headers[7].label)")
        XCTAssertFalse(entry(app, "tools.1").exists, "The overview must not show section entries")
        let screenHeight = app.windows.firstMatch.frame.height
        XCTAssertGreaterThan(headers[0].frame.minY, screenHeight * 0.35, "The overview must open at its medium detent")
        keepScreenshot(named: "agent-instructions-overview")

        headers[1].tap()
        let subagent = entry(app, "tools.1")
        XCTAssertTrue(subagent.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(subagent.label.contains("subagent") && subagent.label.contains("Package"), subagent.label)
        XCTAssertTrue(entry(app, "tools.2").label.contains("Tron"))
        let purpose = app.descendants(matching: .any)["agent-instructions-purpose"]
        XCTAssertGreaterThan(purpose.frame.minY, screenHeight * 0.35, "A section sheet must open at its medium detent")
        keepScreenshot(named: "agent-instructions-tools-sheet")
        dismissTopSheet(app, revealing: headers[2])

        headers[2].tap()
        XCTAssertTrue(entry(app, "rules.1").waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(entry(app, "rules.1").label.contains("from subagent"), entry(app, "rules.1").label)
        dismissTopSheet(app, revealing: headers[7])

        headers[7].tap()
        let tronPurpose = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Added by Tron at the start of every turn")).firstMatch
        XCTAssertTrue(tronPurpose.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(labelled(app, "Tron module tron-core").exists, app.debugDescription)
        XCTAssertTrue(labelled(app, "Added each turn").exists, app.debugDescription)
        keepScreenshot(named: "agent-instructions-tron-sheet")
        dismissTopSheet(app, revealing: headers[4])

        headers[4].tap()
        let agents = app.buttons["agent-instructions-entry-project_context.0"]
        XCTAssertTrue(agents.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(agents.label.contains("~/Workspace/project/AGENTS.md"), agents.label)
        agents.tap()
        let fileBody = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Code, tests, and docs ship together.", "Code, tests, and docs ship together."
        )).firstMatch
        XCTAssertTrue(fileBody.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "agent-instructions-file-reader")
    }

    private func entry(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["agent-instructions-entry-\(id)"]
    }

    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Done on the frontmost sheet; the covered overview's Done stays in the tree.
    private func dismissTopSheet(_ app: XCUIApplication, revealing element: XCUIElement) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
        done.element(boundBy: done.count - 1).tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"),
                                 evaluatedWith: app.descendants(matching: .any)["agent-instructions-purpose"])
        wait(for: [closed], timeout: 3)
        XCTAssertTrue(element.exists, app.debugDescription)
    }

    @MainActor
    func testExtensionWidgetsSheetKeepsContentReachableAtAccessibilityXXXL() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tron-extension-widgets-fixture",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let sheet = app.otherElements["session-activity-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        // Every retained entry must still be reachable and read at the largest
        // accessibility size; the sheet scrolls instead of truncating content.
        for label in ["Goal", "Goal active", "Used 12k tokens", "Goal paused (/goal resume)"] {
            let text = app.staticTexts[label]
            if !text.exists { app.swipeUp() }
            XCTAssertTrue(text.waitForExistence(timeout: 3), app.debugDescription)
        }
        let frameText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Frame progress 3 of 5")
        ).firstMatch
        if !frameText.exists { app.swipeUp() }
        XCTAssertTrue(frameText.waitForExistence(timeout: 3), app.debugDescription)
        keepScreenshot(named: "extension-widgets-sheet-accessibility-xxxl")
    }

    @MainActor
    func testSessionPaginationKeepsShowLessBesideShowMoreAndClearOfLogo() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-pagination-fixture"]
        app.launch()
        let more = app.buttons["Show more sessions in Example workspace"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let less = app.buttons["Show less sessions in Example workspace"]
        for _ in 0..<8 where !less.isHittable { app.swipeUp() }
        XCTAssertTrue(more.isHittable)
        XCTAssertTrue(less.isHittable)
        XCTAssertEqual(less.frame.minX - more.frame.maxX, 24, accuracy: 2)
        XCTAssertEqual(less.frame.minY, more.frame.minY, accuracy: 2)
        let logo = app.buttons["dashboard.menu"]
        XCTAssertFalse(less.frame.intersects(logo.frame))
        keepScreenshot(named: "session-pagination-grouped-at-scroll-end")
        more.tap()
        for _ in 0..<8 where !less.isHittable { app.swipeUp() }
        XCTAssertTrue(less.isHittable)
        XCTAssertFalse(more.exists)
        XCTAssertLessThan(less.frame.maxX, logo.frame.minX)
        less.tap()
        XCTAssertFalse(less.exists)
        XCTAssertTrue(more.exists)
    }

    /// Automations is a sheet opened from the Tron menu, not a dashboard: it
    /// opens at medium and expands to large, search narrows the real catalog,
    /// + opens the existing create flow, and a row opens the existing detail.
    /// The same real edit form, reached without the catalog/detail AX trees.
    /// Run against the pre-extraction and current components for visual parity.
    @MainActor
    func testAutomationEditDateControlsVisualParity() {
        continueAfterFailure = false
        executionTimeAllowance = 120
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-automation-fixture", "-automation-date-controls",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if appearance == "dark" { app.launchArguments.append("-automation-dark") }
            app.launch(); defer { app.terminate() }
            XCTAssertTrue(app.navigationBars.staticTexts["Edit Automation"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["automation-date-controls-ready"].waitForExistence(timeout: 10))
            let date = app.buttons["Sep 1, 2026"].firstMatch
            XCTAssertTrue(date.isHittable, app.debugDescription)
            let time = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'AM' OR label ENDSWITH 'PM'")).firstMatch
            XCTAssertTrue(time.isHittable)
            XCTAssertEqual(date.frame.midY, time.frame.midY, accuracy: 1, "Existing Automations keeps its paired value capsules")
            keepScreenshot(named: "automation-edit-date-fields-\(appearance)")
            date.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Anchor"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            keepScreenshot(named: "automation-edit-calendar-\(appearance)")
            closeTopSheet(app)
            time.tap()
            XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            keepScreenshot(named: "automation-edit-time-\(appearance)")
            closeTopSheet(app)
            XCTAssertTrue(date.isHittable)
            app.terminate()
        }
    }

    @MainActor
    func testAutomationsSheetFromTronMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-automation-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), app.debugDescription)
        menu.tap()
        app.buttons["Automations"].tap()
        let sheetTitle = app.navigationBars.staticTexts["Automations"].firstMatch
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), app.debugDescription)
        let card = app.buttons["automation-card.automation-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), app.debugDescription)

        // Medium detent first, then the large detent after an upward drag.
        let bar = app.navigationBars.containing(.staticText, identifier: "Automations").firstMatch
        XCTAssertGreaterThan(bar.frame.minY, app.frame.height * 0.35, "The sheet opens at the medium detent")
        let window = app.windows.firstMatch
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        )
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { bar.frame.minY < app.frame.height * 0.2 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed, "The sheet expands to the large detent: \(bar.frame)")

        // Search narrows the list to matching names and restores it on close.
        app.buttons["automations.search"].tap()
        app.textFields.firstMatch.typeText("report")
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 3), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["automation-card.automation-2"].exists)
        XCTAssertFalse(app.buttons["automation-card.automation-1"].exists)
        app.buttons["Close search"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["automation-card.automation-1"].exists)

        // + opens the existing create flow over the sheet.
        app.buttons["automations.new"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["New Automation"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)

        for fact in ["Daily workspace review", "Draft", "Every 1 day", "Server, Studio server", "Last run", "Updated", "Sep 1, 2026"] {
            XCTAssertTrue(card.label.contains(fact), "Missing \(fact): \(card.label)")
        }
        XCTAssertTrue(app.buttons["automation-card.automation-1"].label.contains("No runs yet"))
        let status = card.staticTexts["Draft"]
        let title = card.staticTexts["Daily workspace review"]
        XCTAssertTrue(status.exists)
        XCTAssertLessThanOrEqual(status.frame.minY, title.frame.minY + 8, "Status belongs in the top corner, not below the title")
        XCTAssertEqual(status.frame.maxX, card.frame.maxX - 14, accuracy: 2)
        XCTAssertLessThan(card.frame.height, 130, "Inline metadata should not recreate the tall divided card")
        keepScreenshot(named: "automation-inventory-summary-cards")
        card.tap()
        let summary = app.otherElements["automation-detail-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(summary.staticTexts["Daily workspace review"].exists, app.debugDescription)
        let detail = app.scrollViews.containing(.other, identifier: "automation-detail-summary").firstMatch
        let updated = summary.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Updated")).firstMatch
        XCTAssertTrue(updated.exists, app.debugDescription)
        XCTAssertTrue(updated.label.contains("Sep 20, 2026"), "Detail must use the newer record, not the selected catalog summary: \(updated.label)")
        XCTAssertEqual(detail.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Server,")).count, 1)
        let promptLabel = "Prompt, Review the workspace and summarize changes since the previous run. Do not modify files."
        XCTAssertTrue(app.staticTexts[promptLabel].exists, app.debugDescription)
        XCTAssertFalse(app.buttons[promptLabel].exists)
        keepScreenshot(named: "automation-detail-expanded-summary-and-tables")
        let recent = app.staticTexts["RECENT RUNS"]
        for _ in 0..<6 where !recent.isHittable { app.swipeUp() }
        XCTAssertTrue(recent.isHittable, app.debugDescription)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.isHittable)
        XCTAssertLessThan(delete.frame.maxY, recent.frame.minY)
        keepScreenshot(named: "automation-detail-controls-before-history")
        let run = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Succeeded")).firstMatch
        XCTAssertTrue(run.isHittable, app.debugDescription)
        run.tap()
        XCTAssertTrue(app.staticTexts["Run Details"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Archive and Unarchive follow Delete's flow: the swipe reveals the
    /// action, the tap asks for confirmation, and only the confirmation commits.
    /// The journey therefore proves that the revealed action alone changes
    /// nothing, then confirms.
    @MainActor
    private func swipeTapAndConfirm(
        _ row: XCUIElement,
        action identifier: String,
        in app: XCUIApplication,
        screenshot: String? = nil
    ) {
        row.swipeLeft()
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.tap()
        let confirm = app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["confirmation-primary-content", "confirmation-primary-toolbar"])
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.exists, "The row must not move before the change is confirmed")
        if let screenshot { keepScreenshot(named: screenshot) }
        confirm.tap()
    }

    @MainActor
    func testSessionArchiveConfirmationAndArchivedContainerJourney() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-archive-fixture"]
        app.launch()
        defer { app.terminate() }

        let liveRow = app.buttons["session-row-fixture:live-session"]
        XCTAssertTrue(liveRow.waitForExistence(timeout: 8), app.debugDescription)
        // A zero archived count keeps the container off the dashboard.
        XCTAssertFalse(app.buttons["archived-sessions-container"].exists)

        swipeTapAndConfirm(
            liveRow,
            action: "session-archive-action-fixture:live-session",
            in: app,
            screenshot: "session-archive-confirmation"
        )

        let container = app.buttons["archived-sessions-container"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(container.value as? String, "1")
        XCTAssertFalse(app.buttons["session-row-fixture:live-session"].exists)
        keepScreenshot(named: "session-archive-container-collapsed")

        container.tap()
        let archivedRow = app.buttons["archived-session-row-fixture:live-session"]
        XCTAssertTrue(archivedRow.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "session-archive-container-expanded")

        swipeTapAndConfirm(archivedRow, action: "session-unarchive-action-fixture:live-session", in: app)

        // The count returns to zero, so the container hides and the session is
        // back among its workspace rows.
        XCTAssertTrue(app.buttons["session-row-fixture:live-session"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["archived-sessions-container"].waitForExistence(timeout: 2))
        keepScreenshot(named: "session-archive-unarchived")
    }

    /// The archived header is the dashboard's last section, so its rows publish
    /// below the fold. Expanding must move the list up until they are on screen,
    /// and the header's own icon is now the whole loading affordance: there is no
    /// placeholder row to show instead.
    @MainActor
    func testSessionArchiveExpansionRevealsRowsInView() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-archive-fixture", "-tron-session-archive-reveal-fixture"]
        app.launch()
        defer { app.terminate() }

        let container = app.buttons["archived-sessions-container"]
        // The list is much longer than the screen, so the header starts off screen
        // and the journey scrolls the dashboard to its end.
        XCTAssertFalse(container.isHittable, app.debugDescription)
        for _ in 0..<12 where !container.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(container.isHittable, app.debugDescription)
        XCTAssertGreaterThan(
            container.frame.minY,
            app.frame.midY,
            "The archived header must start at the bottom of the screen"
        )
        let headerMinYBeforeExpanding = container.frame.minY
        keepScreenshot(named: "session-archive-reveal-before")

        let firstRow = app.buttons["archived-session-row-fixture:archived-session-0"]
        container.tap()
        // The fixture gates its first page read, so the loading window is
        // observable: the header is expanded and no row has published yet. The
        // placeholder row this journey replaced never appears.
        XCTAssertFalse(firstRow.waitForExistence(timeout: 1), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Loading archived sessions…"].exists, app.debugDescription)
        keepScreenshot(named: "session-archive-reveal-loading")

        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), app.debugDescription)
        // The reveal is animated, so wait for the row to be inside the visible
        // frame rather than sampling the scroll the moment it publishes.
        let rowIsVisible = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return element.isHittable
        }
        expectation(for: rowIsVisible, evaluatedWith: firstRow)
        waitForExpectations(timeout: 10)

        // The list moved up to make room: the revealed rows are in view, the
        // header is still visible and above its pre-expansion position, and the
        // section's own rows sit below it.
        XCTAssertLessThan(container.frame.minY, headerMinYBeforeExpanding, app.debugDescription)
        XCTAssertTrue(container.isHittable, app.debugDescription)
        XCTAssertGreaterThan(firstRow.frame.minY, container.frame.minY, app.debugDescription)
        // The revealed row is inside the usable area, not peeking past the
        // bottom edge behind the home indicator.
        XCTAssertLessThan(
            firstRow.frame.maxY,
            app.frame.maxY - 40,
            "The revealed row must be fully on screen"
        )
        XCTAssertFalse(app.staticTexts["Loading archived sessions…"].exists, app.debugDescription)
        keepScreenshot(named: "session-archive-reveal-after")
    }

    @MainActor
    func testSessionArchivePagingRetiresInFlightPassAndRestartsRefusedCursor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-session-archive-fixture", "-tron-session-archive-paging-fixture"]
        app.launch()
        defer { app.terminate() }

        let liveRow = app.buttons["session-row-fixture:live-session"]
        XCTAssertTrue(liveRow.waitForExistence(timeout: 8), app.debugDescription)
        let container = app.buttons["archived-sessions-container"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), app.debugDescription)
        // The fixture serves one archived session per page, so the first pass
        // both populates the container and offers Show more.
        XCTAssertEqual(container.value as? String, "1", app.debugDescription)

        // Expanding starts the pass whose first read hangs. Archiving the live
        // row then advances the archive projection while that read is still in
        // flight, which is exactly the reload that a dropped pass would lose.
        container.tap()
        swipeTapAndConfirm(liveRow, action: "session-archive-action-fixture:live-session", in: app)

        let archivedLiveRow = app.buttons["archived-session-row-fixture:live-session"]
        XCTAssertTrue(archivedLiveRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["archived-session-row-fixture:older-session"].exists, app.debugDescription)

        // A continuation the Gateway refuses is replaced by that server's first
        // page: the rows stay, and no server is reported unavailable. The
        // control's label carries the section it expands.
        let showMore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show more")).firstMatch
        XCTAssertTrue(showMore.waitForExistence(timeout: 5), app.debugDescription)
        showMore.tap()
        XCTAssertTrue(archivedLiveRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(showMore.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Archived sessions unavailable"))
                .firstMatch.exists,
            app.debugDescription
        )
        keepScreenshot(named: "session-archive-paging-restart")
    }

    /// #1123: tapping Other focuses its editor, expands the sheet and keeps
    /// the whole editor above the keyboard, including multi-line growth.
    @MainActor
    func testAskUserOtherTapFocusesEditorAboveKeyboard() {
        let app = launchAskUser()
        waitForAskUserForm(in: app)
        let send = app.buttons["Submit all answers"]
        let mediumY = send.frame.minY
        XCTAssertGreaterThan(mediumY, app.frame.height * 0.4)
        app.buttons["Staging"].tap()
        app.buttons["Other"].tap()
        let editor = app.textViews["Other response for Environment"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Tapping Other must focus its editor: \(app.debugDescription)")
        expectation(for: NSPredicate { _, _ in send.frame.minY < mediumY - 100 }, evaluatedWith: send)
        waitForExpectations(timeout: 5)
        assertAskUserEditorAboveKeyboard(editor, keyboard: keyboard)
        keepScreenshot(named: "ask-user-other-focused-above-keyboard")
        editor.typeText((1...8).map { "Line \($0)" }.joined(separator: "\n"))
        assertAskUserEditorAboveKeyboard(editor, keyboard: keyboard)
        keepScreenshot(named: "ask-user-other-multiline-above-keyboard")
        // A content drag scrolls the page and stays put; it must not resize
        // the sheet or snap the page back.
        let staging = app.buttons["Staging"]
        let before = staging.frame.minY
        staging.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: staging.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2.5)))
        let scrolled = NSPredicate { _, _ in staging.frame.minY > before + 15 }
        expectation(for: scrolled, evaluatedWith: staging)
        waitForExpectations(timeout: 3)
        let settled = staging.frame.minY
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(staging.frame.minY, settled, accuracy: 2, "The page snapped back after the drag")
        XCTAssertLessThan(send.frame.minY, mediumY - 100, "A content drag resized the sheet")
        app.buttons["Other"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Staging"].value as? String, "Selected")
        swipeDownAskUserSheet(in: app)
        XCTAssertTrue(app.buttons["Reopen Ask User"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].exists)
    }

    /// Failure mode: Send on a paged single-choice form while the last page's
    /// Other editor holds the keyboard hangs the app before the answer is sent.
    @MainActor
    func testAskUserSendWithFocusedOtherEditorOnLastPageSubmits() {
        let app = launchAskUser(styled: true, multiple: true)
        let staging = app.buttons["Staging, A pre-release environment for validation."]
        XCTAssertTrue(staging.waitForExistence(timeout: 5), app.debugDescription)
        staging.tap()
        app.textViews["Which environments should receive the change?"].swipeLeft()
        XCTAssertTrue(app.textViews["When should the change happen?"].waitForExistence(timeout: 3), app.debugDescription)
        let other = app.buttons.matching(NSPredicate(format: "label == %@", "Other"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(other, app.debugDescription)
        other?.tap()
        let editor = app.textViews["Other response for When should the change happen?"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        editor.typeText("After the review")
        keepScreenshot(named: "ask-user-last-page-other-focused")
        app.buttons["Submit all answers"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].waitForExistence(timeout: 10), app.debugDescription)
        keepScreenshot(named: "ask-user-last-page-other-submitted")
    }

    @MainActor
    func testAskUserSingleChoiceOtherEditorHidesWhenChoosingAnOption() {
        let app = launchAskUser(styled: true)
        let send = app.buttons["Submit all answers"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        app.buttons["Other"].tap()
        let editor = app.textViews["Other response for Environment"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        editor.typeText("A custom environment")
        app.buttons["Staging, A pre-release environment for validation."].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Submit all answers"].isEnabled)
        keepScreenshot(named: "ask-user-other-editor-hidden-single-choice")
    }

    /// #1123: swiping the sheet down is the only local close. It sends no
    /// response, so the question stays pending and reopens with its draft.
    @MainActor
    func testAskUserSwipeDismissKeepsQuestionPendingWithDraft() {
        let app = launchAskUser()
        waitForAskUserForm(in: app)
        app.buttons["Staging"].tap()
        app.buttons["Other"].tap()
        let other = app.textViews["Other response for Environment"]
        XCTAssertTrue(other.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        other.typeText("local canary")
        XCTAssertFalse(app.buttons["Close form and keep answers"].exists, "The X close button is gone")
        swipeDownAskUserSheet(in: app)
        XCTAssertTrue(app.buttons["Reopen Ask User"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].exists)
        keepScreenshot(named: "ask-user-swipe-dismissed-pending")
        app.buttons["Reopen Ask User"].tap()
        XCTAssertTrue(app.buttons["Staging"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Staging"].value as? String, "Selected")
        let restored = app.textViews["Other response for Environment"]
        XCTAssertTrue(restored.waitForExistence(timeout: 3))
        restored.tap()
        app.buttons["Submit all answers"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=environment-a other=local canary"].exists)
    }

    @MainActor
    func testAskUserWithoutAllowCancelHasSendOnlyAndSwipeCloses() {
        let app = launchAskUser(noCancel: true)
        waitForAskUserForm(in: app)
        XCTAssertFalse(app.buttons["Cancel form"].exists)
        XCTAssertTrue(app.buttons["Submit all answers"].exists)
        swipeDownAskUserSheet(in: app)
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Reopen Ask User"].exists)
    }

    @MainActor
    func testAskUserSubmitRendersExactReadOnlyCompletedForm() {
        let app = launchAskUser()
        waitForAskUserForm(in: app)
        app.buttons["Staging"].tap()
        app.buttons["Production"].tap()
        app.buttons["Other"].tap()
        let other = app.textViews["Other response for Environment"]
        XCTAssertTrue(other.waitForExistence(timeout: 3))
        other.tap()
        other.typeText("A canary region")
        app.buttons["Submit all answers"].tap()
        XCTAssertTrue(app.staticTexts["Choose deployment target"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Other"].exists)
        XCTAssertTrue(app.staticTexts["A canary region"].exists)
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].exists)
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=environment-a,environment-b other=A canary region"].exists)
        XCTAssertFalse(app.textViews["Other response for Environment"].exists)
        keepScreenshot(named: "ask-user-completed-read-only-fixture")
    }

    /// #941: agent-authored question text is selectable with Copy, its URL is
    /// a tappable link, and a fenced command's shared Copy control copies the
    /// exact command (proved by pasting it into Other and submitting it with an
    /// option through the real response path).
    @MainActor
    func testAskUserQuestionTextIsSelectableWithLinksAndCopyableCode() {
        let command = "scripts/tron-ios-device share --commit 1955237"
        let url = "https://build.example.ts.net:8443/"
        let app = launchAskUser(copyable: true)
        waitForAskUserForm(in: app)
        let question = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", url)).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(question.links[url].exists, "The bare URL is a link: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts[command].exists, "The fenced command renders as a code block")
        keepScreenshot(named: "941-1-question-url-command")

        // Native range selection on the question offers the system Copy.
        question.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2)).press(forDuration: 1.0)
        let copyMenu = app.descendants(matching: .menuItem).matching(NSPredicate(format: "label == 'Copy'")).firstMatch
        XCTAssertTrue(copyMenu.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "941-2-question-selection-copy-menu")
        copyMenu.tap()

        // The code block's shared Copy control copies the exact command.
        let copyCode = app.buttons.matching(NSPredicate(format: "label == 'Copy'")).firstMatch
        XCTAssertTrue(copyCode.waitForExistence(timeout: 3), app.debugDescription)
        copyCode.tap()

        app.buttons["Staging"].tap()
        app.buttons["Other"].tap()
        let other = app.textViews["Other response for Environment"]
        XCTAssertTrue(other.waitForExistence(timeout: 3), app.debugDescription)
        other.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        other.press(forDuration: 1.0)
        let paste = app.descendants(matching: .menuItem).matching(NSPredicate(format: "label == 'Paste'")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        XCTAssertEqual(other.value as? String, command)
        app.buttons["Submit all answers"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 1"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["extension.respond cancelled=false selected=environment-a other=\(command)"].exists, app.debugDescription)

        // The completed review renders the same link; tapping it opens Safari.
        let reviewed = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", url)).firstMatch
        XCTAssertTrue(reviewed.waitForExistence(timeout: 5), app.debugDescription)
        keepScreenshot(named: "941-4-completed-review-link")
        reviewed.links[url].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), "The question link opens in Safari")
        keepScreenshot(named: "941-5-link-opened")
        app.activate()
    }

    @MainActor
    func testAskUserInstructionAndSeparateToolbarLayout() {
        let app = launchAskUser(styled: true)
        let question = app.textViews["Which environments should receive the change?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        let instruction = app.staticTexts["Select one. Question 1 of 1"]
        let option = app.buttons["Staging, A pre-release environment for validation."]
        XCTAssertTrue(instruction.exists)
        XCTAssertTrue(option.exists)
        XCTAssertLessThanOrEqual(instruction.frame.maxY, question.frame.minY)
        XCTAssertLessThanOrEqual(question.frame.maxY, option.frame.minY)
        let cancel = app.buttons["Cancel form"]
        let send = app.buttons["Submit all answers"]
        XCTAssertTrue(cancel.isHittable)
        XCTAssertLessThan(cancel.frame.maxX, send.frame.minX)
        XCTAssertFalse(app.buttons["Close form and keep answers"].exists)
        XCTAssertFalse(send.isEnabled)
        // #1123: no fixed opaque header. The instruction is page content that
        // starts below the toolbar, and the page's scroll viewport extends up
        // beneath the toolbar into the shared top blur.
        let page = app.scrollViews["Question 1 of 1"]
        XCTAssertTrue(page.exists, app.debugDescription)
        XCTAssertGreaterThan(instruction.frame.minY, send.frame.maxY)
        XCTAssertLessThanOrEqual(page.frame.minY, send.frame.minY)
        keepScreenshot(named: "ask-user-styled-active-disabled")
        option.tap()
        XCTAssertTrue(app.buttons["Submit all answers"].isEnabled)
        keepScreenshot(named: "ask-user-styled-active-selected")
    }

    /// #1123: a page taller than the sheet scrolls under content drags, in
    /// both directions, without resizing the sheet or snapping back.
    @MainActor
    func testAskUserLongPageScrollsWithContentDrags() {
        let app = launchAskUser(long: true)
        waitForAskUserForm(in: app)
        let send = app.buttons["Submit all answers"]
        let sheetY = send.frame.minY
        let context = app.textViews.firstMatch
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        var positions = [context.frame.minY]
        for offset in [-120.0, -120.0, 120.0] {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: offset)), withVelocity: .slow, thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: 0.6)
            positions.append(context.frame.minY)
            XCTAssertEqual(send.frame.minY, sheetY, accuracy: 2, "A content drag resized the sheet")
        }
        XCTAssertLessThan(positions[1], positions[0] - 60, "The page did not scroll: \(positions)")
        XCTAssertLessThan(positions[2], positions[1] - 60, "The page did not keep scrolling: \(positions)")
        XCTAssertGreaterThan(positions[3], positions[2] + 60, "Dragging back did not scroll the page back: \(positions)")
        keepScreenshot(named: "ask-user-long-page-scrolled")
    }

    /// #1155: pages follow horizontal drags without a nested pager. Vertical
    /// drags scroll a long page and never turn it; a short horizontal drag
    /// springs back; a long one turns the page either way; neither resizes nor
    /// dismisses the sheet; Other still focuses above the keyboard; and a
    /// swipe-down close keeps the page's draft.
    @MainActor
    func testAskUserPagesFollowHorizontalDragsAndKeepVerticalScroll() {
        let app = launchAskUser(multiple: true, long: true)
        waitForAskUserForm(in: app)
        let send = app.buttons["Submit all answers"]
        let sheetY = send.frame.minY
        let firstPage = app.scrollViews["Question 1 of 2"]
        let secondPage = app.scrollViews["Question 2 of 2"]
        XCTAssertTrue(firstPage.exists, app.debugDescription)
        XCTAssertFalse(secondPage.exists, "Only the visible page is mounted at rest")
        let context = app.textViews.firstMatch
        let restX = context.frame.minX
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        func drag(dx: Double, dy: Double) {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)), withVelocity: .slow, thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: 0.7)
        }

        // A vertical drag scrolls the long page and does not turn it.
        let beforeScroll = context.frame.minY
        drag(dx: 0, dy: -160)
        XCTAssertLessThan(context.frame.minY, beforeScroll - 60, "The page did not scroll")
        XCTAssertTrue(firstPage.exists)
        XCTAssertFalse(secondPage.exists)
        XCTAssertEqual(context.frame.minX, restX, accuracy: 1, "A vertical drag moved the page sideways")
        XCTAssertEqual(send.frame.minY, sheetY, accuracy: 2, "A content drag resized the sheet")

        // A short horizontal drag springs back to the same page.
        let scrolledY = context.frame.minY
        drag(dx: -50, dy: 0)
        XCTAssertTrue(firstPage.exists)
        XCTAssertFalse(secondPage.exists, "The peeked page stays mounted after spring-back")
        XCTAssertEqual(context.frame.minX, restX, accuracy: 1, "The page did not spring back")
        XCTAssertEqual(context.frame.minY, scrolledY, accuracy: 2, "A horizontal drag scrolled the page")

        // A long, slightly diagonal drag turns the page; it neither scrolls,
        // resizes nor starts dismissing the sheet.
        drag(dx: -240, dy: 30)
        XCTAssertTrue(secondPage.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(firstPage.exists, "The previous page stays mounted after the turn")
        let timing = app.textViews["When should the change happen?"]
        XCTAssertEqual(timing.frame.minX, restX, accuracy: 1, "The new page did not settle in place")
        XCTAssertEqual(send.frame.minY, sheetY, accuracy: 2, "A page drag resized or dismissed the sheet")
        keepScreenshot(named: "ask-user-page-2-after-drag")

        // Dragging back returns to the first page; dragging past the last
        // page bounces back without turning.
        drag(dx: 240, dy: 0)
        XCTAssertTrue(firstPage.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(secondPage.exists)
        drag(dx: -240, dy: 0)
        XCTAssertTrue(secondPage.waitForExistence(timeout: 3), app.debugDescription)
        drag(dx: -240, dy: 0)
        XCTAssertTrue(secondPage.exists, "Dragging past the last page turned it")
        XCTAssertEqual(timing.frame.minX, restX, accuracy: 1, "The last page did not bounce back")

        // Other on the turned page focuses above the keyboard, and a swipe-
        // down close keeps the page and its draft pending.
        app.buttons["Other"].tap()
        let editor = app.textViews["Other response for When should the change happen?"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Tapping Other must focus its editor: \(app.debugDescription)")
        assertAskUserEditorAboveKeyboard(editor, keyboard: keyboard)
        editor.typeText("After review")
        swipeDownAskUserSheet(in: app)
        XCTAssertTrue(app.buttons["Reopen Ask User"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].exists)
        app.buttons["Reopen Ask User"].tap()
        XCTAssertTrue(secondPage.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.textViews["Other response for When should the change happen?"].value as? String, "After review")
    }

    @MainActor
    private func launchAskUser(noCancel: Bool = false, styled: Bool = false, multiple: Bool = false, copyable: Bool = false, long: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-ask-user-fixture"]
        if noCancel { app.launchArguments.append("-tron-ask-user-no-cancel") }
        if styled { app.launchArguments.append("-tron-ask-user-styled") }
        if multiple { app.launchArguments.append("-tron-ask-user-multiple") }
        if copyable { app.launchArguments.append("-tron-ask-user-copyable") }
        if long { app.launchArguments.append("-tron-ask-user-long") }
        app.launch()
        return app
    }

    /// Drags the sheet down from its toolbar title, the interactive dismissal.
    @MainActor
    private func swipeDownAskUserSheet(in app: XCUIApplication) {
        let send = app.buttons["Submit all answers"]
        let window = app.windows.firstMatch
        let title = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: send.frame.midY))
        title.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(send.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func assertAskUserEditorAboveKeyboard(_ editor: XCUIElement, keyboard: XCUIElement) {
        let visible = NSPredicate { _, _ in
            editor.frame.minY >= 0 && editor.frame.maxY + 16 <= keyboard.frame.minY
        }
        expectation(for: visible, evaluatedWith: editor)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func waitForAskUserForm(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Choose deployment target"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Staging"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Production"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "ask-user-form-fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertWelcomeVisualParity() {
        guard let referenceURL = Bundle(for: Self.self).url(
            forResource: "onboarding-welcome-medium-historical",
            withExtension: "png"
        ), let reference = UIImage(contentsOfFile: referenceURL.path)?.cgImage,
           let current = XCUIScreen.main.screenshot().image.cgImage else {
            return XCTFail("Historical onboarding visual reference is missing")
        }
        // The executable historical artifact is an iPhone 17 Pro baseline.
        // Larger physical devices retain geometry assertions and screenshots,
        // but must not be resampled into a misleading feature-print comparison.
        guard reference.width == current.width, reference.height == current.height else { return }
        let crop = CGRect(x: 0, y: 1242, width: 1206, height: 1380)
        guard let referenceCrop = reference.cropping(to: crop),
              let currentCrop = current.cropping(to: crop) else {
            return XCTFail("Onboarding screenshots must retain the iPhone 17 Pro reference dimensions")
        }
        do {
            let historical = try featurePrint(referenceCrop)
            let rendered = try featurePrint(currentCrop)
            var distance: Float = 0
            try historical.computeDistance(&distance, to: rendered)
            XCTAssertLessThan(distance, 0.38, "Medium onboarding sheet drifted from the executable historical baseline")
        } catch {
            XCTFail("Could not compare onboarding visuals: \(error)")
        }
    }

    private func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        if let cpu = MLComputeDevice.allComputeDevices.first(where: {
            if case .cpu = $0 { return true }
            return false
        }) {
            for (stage, devices) in try request.supportedComputeStageDevices where devices.contains(cpu) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw VisualParityFailure.noFeaturePrint
        }
        return observation
    }

    private enum VisualParityFailure: Error { case noFeaturePrint }

    @MainActor
    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertAccessibilityAuditPasses(_ app: XCUIApplication) {
        var failures: [String] = []
        XCTAssertNoThrow(try app.performAccessibilityAudit { issue in
            let element = issue.element
            // XCTest predicts clipping from the field's normal-size UIKit host
            // frame without rerunning SwiftUI layout. The dedicated XXXL test
            // above relaunches and verifies the real custom field grows.
            if issue.auditType == .textClipped,
               element?.label == "Tailscale host",
               element?.elementType == .textField { return true }
            failures.append("\(issue.compactDescription): \(issue.detailedDescription) [label=\(element?.label ?? "nil"), id=\(element?.identifier ?? "nil"), frame=\(String(describing: element?.frame)), element=\(element?.debugDescription ?? "nil")]")
            return true
        })
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    @MainActor
    private func launchResetApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tron-reset-ui-test-state", "-ApplePersistenceIgnoreState", "YES"] + extraArguments
        app.launch()
        return app
    }
}
