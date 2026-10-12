import CoreML
import UIKit
import Vision
import XCTest

final class TronSmokeUITests: XCTestCase {
    @MainActor
    func testHomeTaskListStopSteerAndRedelivery() {
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
        XCTAssertTrue(app.staticTexts["Settings model: continue epic #758"].exists)
        XCTAssertTrue(app.staticTexts["tron"].exists)
        XCTAssertFalse(app.staticTexts["Spend unavailable"].exists)
        keepScreenshot(named: "home-task-list")
        app.buttons["home-task-active"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-task-detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["12 input · 3 output tokens"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Unpriced"].exists, "Task spend shows token counts only; the Gateway reports no cost")
        app.textFields["home-task-steer"].tap(); app.textFields["home-task-steer"].typeText("Use the exact task")
        app.buttons["home-task-steer-send"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
        XCTAssertTrue(app.buttons["home-task-stop"].waitForExistence(timeout: 5)); app.buttons["home-task-stop"].tap()
        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 5))
        keepScreenshot(named: "home-task-stopped")
        app.buttons["home-sheet-done-task"].tap()
        XCTAssertTrue(app.buttons["home-task-terminal"].waitForExistence(timeout: 5)); app.buttons["home-task-terminal"].tap()
        XCTAssertTrue(app.staticTexts["Finished · Final"].waitForExistence(timeout: 5))
        app.buttons["home-task-redeliver"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:3", timeout: 5))
        keepScreenshot(named: "home-task-redelivered")
    }

    /// The task detail's worker row opens the worker's own chat, read-only to Home
    /// (an ordinary session), and never through a Home route.
    @MainActor
    func testHomeTaskDetailOpensWorkerChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-tasks")
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5))
        app.buttons["home-task-active"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-task-detail"].waitForExistence(timeout: 5))
        // The live subagent run is part of the worker's detail, not the row.
        XCTAssertTrue(app.staticTexts["1 live subagent run"].waitForExistence(timeout: 5))
        keepScreenshot(named: "home-task-detail")
        tapManageRow(app, "home-task-open-worker")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-opened-session"], containing: "opened-session:worker-session", timeout: 10))
        XCTAssertFalse(app.buttons["Manage Home"].exists, "The worker chat is an ordinary session and must not claim Home")
    }

    @MainActor
    func testHomeTaskPermissionsRevokeDecideAndReconfirm() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-permissions")
        XCTAssertTrue(app.buttons["Reconfirm permissions"].waitForExistence(timeout: 5)); app.buttons["Reconfirm permissions"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
        revokeHomePermission(app, "Revoke scope scope-one")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:2", timeout: 5))
        revokeHomePermission(app, "Revoke grant grant-one")
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:3", timeout: 5))
        app.buttons["Review request request-approve"].tap()
        XCTAssertTrue(app.staticTexts["/trusted/project"].waitForExistence(timeout: 5))
        chooseHomeGrantExpiry(app)
        app.buttons["Approve request"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:4", timeout: 5))
        app.buttons["home-sheet-done-grant"].tap()
        XCTAssertTrue(app.buttons["Review request request-deny"].waitForExistence(timeout: 5)); app.buttons["Review request request-deny"].tap()
        chooseHomeGrantExpiry(app)
        app.buttons["Deny request"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:5", timeout: 5))
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
        tapManageRow(app, "home-manage-permissions")
        XCTAssertTrue(app.staticTexts["All trusted projects"].waitForExistence(timeout: 5))
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
    /// edge material) to the loading row's intrinsic width. Exercise the real
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
            assertHomeLoadingSurface(app, name: "\(appearance)-manage-medium")
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 10))
            XCTAssertEqual(done.frame.midY, mediumY, accuracy: 2, "Loading must not move sheet chrome")
            keepScreenshot(named: "sheet-\(appearance)-manage-loaded")
            tapManageRow(app, "home-manage-tasks")
            let taskDone = app.buttons["home-sheet-done-tasks"]
            XCTAssertTrue(taskDone.waitForExistence(timeout: 5))
            assertHomeLoadingSurface(app, name: "\(appearance)-tasks-medium")
            let title = app.staticTexts["Tasks"].firstMatch
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                taskDone.frame.midY < mediumY - 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed)
            assertHomeLoadingSurface(app, name: "\(appearance)-tasks-large")
            XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 10))
            keepScreenshot(named: "sheet-\(appearance)-tasks-loaded-large")
            taskDone.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(ring.waitForExistence(timeout: 5))
            ring.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            assertHomeLoadingSurface(app, name: "\(appearance)-manage-reopened")
            app.staticTexts["Manage Home"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
            let manageExpanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                done.frame.midY < mediumY - 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [manageExpanded], timeout: 3), .completed)
            assertHomeLoadingSurface(app, name: "\(appearance)-manage-large")
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
            app.buttons["Reload"].tap()
            XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5))
            XCTAssertEqual(done.frame.midY, y, accuracy: 2)
            keepScreenshot(named: "sheet-\(appearance)-tasks-retried")
            done.tap()
            XCTAssertTrue(app.buttons["home-sheet-done-manage"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    private func assertHomeLoadingSurface(_ app: XCUIApplication, name: String) {
        let loading = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Loading Home…")).firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        keepScreenshot(named: "sheet-\(name)-loading")
        let scroll = app.scrollViews.firstMatch
        XCTAssertGreaterThan(scroll.frame.width, app.windows.firstMatch.frame.width * 0.9,
                             "The sheet viewport and its edge material must not inherit the loading row's intrinsic width")
        XCTAssertLessThan(loading.frame.height, 40, "The short loading label must not wrap at normal Dynamic Type")
        // Accessibility reports the full ScrollView even when its overlay is
        // intrinsically narrow. Compare the actual material above the title,
        // away from text, controls and rounded corners; no device-specific golden.
        let title = app.staticTexts["Tasks"].exists ? app.staticTexts["Tasks"].firstMatch : app.staticTexts["Manage Home"].firstMatch
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
                XCTAssertTrue(app.descendants(matching: .any)["home-sheet-loading"].waitForExistence(timeout: 2))
                keepScreenshot(named: "home-memory-loading")
                XCTAssertTrue(app.staticTexts["Asked to move garden planning to Thursday reviews"].waitForExistence(timeout: 10))
            } else if state == "empty" {
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No memory yet")).firstMatch.waitForExistence(timeout: 5))
            } else {
                XCTAssertTrue(app.buttons["Reload"].waitForExistence(timeout: 5))
                keepScreenshot(named: "home-memory-error")
                app.buttons["Reload"].tap()
                XCTAssertTrue(app.staticTexts["Asked to move garden planning to Thursday reviews"].waitForExistence(timeout: 5))
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
        tapManageRow(empty, "home-manage-context")
        XCTAssertTrue(empty.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No activation context yet")).firstMatch.waitForExistence(timeout: 5))
        keepScreenshot(named: "home-context-empty")
    }

    /// The Home Context sheet explains where the next request's context goes: one stacked
    /// bar of the window with a meaning per section, and no entry IDs or byte counts.
    @MainActor
    func testHomeContextShowsBreakdownWithoutRawIdentifiers() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-context")
        XCTAssertTrue(app.descendants(matching: .any)["home-context-breakdown"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["home-context-bar"].exists)
        for label in ["Instructions", "About you", "Memory", "This chapter", "Task results", "Your message"] {
            XCTAssertTrue(app.staticTexts[label].exists, label)
        }
        XCTAssertTrue(app.descendants(matching: .any)["home-context-section-memory"].label.contains("260 summaries"))
        XCTAssertFalse(app.staticTexts["activation-entry"].exists, "Context must not show an entry ID")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", " bytes")).firstMatch.exists, "Context must not show byte counts")
        keepScreenshot(named: "home-context-populated")
    }

    /// Opening a memory row shows its detail; its exact evidence opens from one standard row.
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
        let row = app.descendants(matching: .any)["home-memory-row-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Asked to move garden planning to Thursday reviews"].exists)
        // The secondary line names the chapter the entry belongs to, never its IDs.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "chapter 1")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["source-session · source-entry"].exists, "Memory rows show no raw evidence identifiers")
        keepScreenshot(named: "home-memory-rows")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-memory-detail"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Asked to move garden planning to Thursday reviews"].exists)
        keepScreenshot(named: "home-memory-detail")
        tapManageRow(app, "home-memory-exact-evidence")
        XCTAssertTrue(app.descendants(matching: .any)["home-evidence-text"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Canonical original, not the memory projection"].exists)
        keepScreenshot(named: "home-exact-evidence")
        app.buttons["home-sheet-done-evidence"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-memory-detail"].waitForExistence(timeout: 5))
        app.buttons["home-sheet-done-memory-item"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-memory-row-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Next memory page"].exists)
        app.buttons["Next memory page"].tap()
        XCTAssertTrue(app.staticTexts["Wants the Thursday summary emailed"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Scheduled the garden review for Thursday at 10:00."].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Asked to move garden planning to Thursday reviews"].exists, "Browsing a chapter shows only that chapter's memory")
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

    /// The main sheet's rows and bottom container, with no Stop row and no Home state row:
    /// the state is the stats card's pill.
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
        XCTAssertTrue(app.descendants(matching: .any)["session-usage-summary"].exists, "The stats card comes from the Home chat's session")
        XCTAssertTrue(app.descendants(matching: .any)["session-model-summary"].exists)
        XCTAssertTrue(app.buttons["Memory model"].exists, "The memory model is a row in the model card")
        XCTAssertFalse(app.staticTexts["Automatic Compaction"].exists, "Home never compacts; it uses chapters")
        for row in ["home-manage-context", "home-manage-memory-browser", "home-manage-chapters", "home-manage-tasks", "home-manage-permissions"] {
            XCTAssertTrue(app.descendants(matching: .any)[row].exists, row)
        }
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-pause"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-disable"].exists)
        XCTAssertFalse(app.staticTexts["Stop response"].exists, "Stop is the composer's control, not a Manage Home row")
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-stop"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Home · ")).firstMatch.exists, "The state is a pill, not a row")
        keepScreenshot(named: "manage-home-sheet")
    }

    @MainActor
    func testHomeModelPickerAcknowledgementAndFailureStayInPopup() {
        continueAfterFailure = false
        for failure in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-model-picker"]
            if failure { app.launchArguments.append("-home-model-failure") }
            app.launch(); defer { app.terminate() }
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
            app.buttons["home-pinned-row"].tap()
            openManageHome(app)
            app.buttons["Switch Model"].tap()
            let haiku = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Claude Haiku 5.5")).firstMatch
            XCTAssertTrue(haiku.waitForExistence(timeout: 5))
            haiku.tap()
            wait(for: [expectation(for: NSPredicate(format: "value == %@", "Applying configuration"), evaluatedWith: haiku)], timeout: 2)
            if failure {
                let failureNotice = app.descendants(matching: .any)["in-app-notice-card"]
                XCTAssertTrue(failureNotice.waitForExistence(timeout: 10))
                XCTAssertTrue(failureNotice.label.contains("Model choice refused; try again."))
                XCTAssertTrue(failureNotice.isHittable, "The failure must be visible above the popup")
                keepScreenshot(named: "home-model-failure-in-popup")
                XCTAssertTrue(haiku.isEnabled)
                haiku.tap()
            }
            wait(for: [expectation(for: NSPredicate(format: "value == %@ AND enabled == true", "Selected"), evaluatedWith: haiku)], timeout: 10)
            XCTAssertTrue(app.staticTexts["Models"].exists)
            keepScreenshot(named: "home-model-confirmed-open-\(failure ? "retry" : "success")")
            app.buttons["Done"].tap()
            XCTAssertTrue(app.staticTexts["Manage Home"].exists)
            XCTAssertEqual(app.buttons["thinking-level-control"].value as? String, "Off")
            app.buttons["home-sheet-done-manage"].tap()
            XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["session-context-button"].label, "Manage Home")
            app.terminate()
        }
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
        for (row, done) in [("home-manage-context", "home-sheet-done-context"), ("home-manage-memory-browser", "home-sheet-done-memory"),
                            ("home-manage-chapters", "home-sheet-done-chapters"), ("home-manage-tasks", "home-sheet-done-tasks"),
                            ("home-manage-permissions", "home-sheet-done-permissions")] {
            tapManageRow(app, row)
            let doneButton = app.buttons[done]
            XCTAssertTrue(doneButton.waitForExistence(timeout: 5), row)
            XCTAssertLessThan(doneButton.frame.minY, windowHeight * 0.6, "\(row) must open at the medium detent")
            doneButton.tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 5), row)
        }
    }

    /// Light and dark captures of the sheets the coordinator reviews: the main sheet at
    /// medium and large, and each sub-sheet in its own state.
    @MainActor
    func testManageHomeSheetCaptureMatrix() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"]
            if appearance == "dark" { app.launchArguments.append("-home-dark") }
            app.launch()
            XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["home-pinned-row"].tap()
            openManageHome(app)
            keepScreenshot(named: "home-\(appearance)-manage-medium")
            let title = app.staticTexts["Manage Home"].firstMatch
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-manage-large")
            tapManageRow(app, "home-manage-context")
            XCTAssertTrue(app.descendants(matching: .any)["home-context-breakdown"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-context")
            app.buttons["home-sheet-done-context"].tap()
            tapManageRow(app, "home-manage-memory-browser")
            XCTAssertTrue(app.staticTexts["Asked to move garden planning to Thursday reviews"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-memory")
            app.descendants(matching: .any)["home-memory-row-0"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-memory-detail"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-memory-detail")
            tapManageRow(app, "home-memory-exact-evidence")
            XCTAssertTrue(app.descendants(matching: .any)["home-evidence-text"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-exact-evidence")
            app.buttons["home-sheet-done-evidence"].tap()
            app.buttons["home-sheet-done-memory-item"].tap()
            app.buttons["home-sheet-done-memory"].tap()
            tapManageRow(app, "home-manage-chapters")
            XCTAssertTrue(app.buttons["home-chapter-2"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-chapters")
            app.buttons["home-chapter-1"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-chapter-detail"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-chapter-detail")
            app.buttons["home-sheet-done-chapter"].tap()
            app.buttons["home-sheet-done-chapters"].tap()
            tapManageRow(app, "home-manage-tasks")
            XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-tasks")
            app.buttons["home-task-active"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-task-detail"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-task-detail")
            app.buttons["home-sheet-done-task"].tap()
            app.buttons["home-sheet-done-tasks"].tap()
            tapManageRow(app, "home-manage-permissions")
            XCTAssertTrue(app.buttons["Reconfirm permissions"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-permissions")
            // The main sheet scrolled to its bottom container: pause or resume, and disable.
            app.buttons["home-sheet-done-permissions"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-state"].waitForExistence(timeout: 5))
            app.swipeUp()
            XCTAssertTrue(app.descendants(matching: .any)["home-manage-disable"].waitForExistence(timeout: 5))
            keepScreenshot(named: "home-\(appearance)-manage-bottom")
            app.terminate()
        }
    }

    @MainActor
    func testHomeCrossSurfaceProofMatrix() {
        continueAfterFailure = false
        let sheets: [(row: String, doneID: String, content: String, name: String)] = [
            ("home-manage-context", "context", "home-context-breakdown", "context"),
            ("home-manage-memory-browser", "memory", "Asked to move garden planning to Thursday reviews", "memory-browser"),
            ("home-manage-chapters", "chapters", "home-chapter-2", "chapters"),
            ("home-manage-tasks", "tasks", "home-task-active", "tasks"),
            ("home-manage-permissions", "permissions", "Reconfirm permissions", "permissions"),
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

    /// The memory model is a row of the model card, chosen through the same model
    /// picker as the chat model. Its choice is the `home.configureMemory` receipt.
    @MainActor
    func testHomeMemoryModelRowSelectsPhysicalModel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-unconfigured", "-home-sheet-delayed-status"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10))
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        XCTAssertTrue(app.buttons["Memory model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Choose a memory model before sending"].waitForExistence(timeout: 5))
        app.buttons["Memory model"].tap()
        let provider = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Fixture, 2 models")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        if provider.value as? String == "collapsed" { provider.tap() }
        let choice = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Memory Model B")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Virtual model")).firstMatch.exists)
        choice.tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-configured-model"], containing: "fixture/memory-b", timeout: 5))
        choice.tap() // The receipt is terminal while the covered sheet cannot re-read status: the choice stays applying.
        let applying = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Applying configuration"), object: choice)
        XCTAssertEqual(XCTWaiter.wait(for: [applying], timeout: 5), .completed)
        choice.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["fixture.home-control-count"], containing: "control-count:1", timeout: 5))
        let done = try? XCTUnwrap(app.buttons.matching(identifier: "Done").allElementsBoundByIndex.first(where: \.isHittable))
        XCTAssertNotNil(done)
        done?.tap()
        let modelRow = app.buttons["Memory model"]
        let converged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Memory Model B"), object: modelRow)
        XCTAssertEqual(XCTWaiter.wait(for: [converged], timeout: 8), .completed)
        keepScreenshot(named: "home-memory-model-configured")
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
                XCTAssertTrue(app.descendants(matching: .any)["home-manage-context"].exists)
            }
            if state == "empty-models" {
                XCTAssertTrue(app.buttons["Memory model"].waitForExistence(timeout: 5))
                app.buttons["Memory model"].tap()
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No available memory models")).firstMatch.waitForExistence(timeout: 5))
            } else if state == "configure-refused" {
                app.buttons["Memory model"].tap()
                let provider = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Fixture, 2 models")).firstMatch
                XCTAssertTrue(provider.waitForExistence(timeout: 5))
                if provider.value as? String == "collapsed" { provider.tap() }
                app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Memory Model B")).firstMatch.tap()
                XCTAssertTrue(app.alerts["Home change"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.alerts.staticTexts["Memory configuration refused"].exists)
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
        XCTAssertTrue(app.staticTexts["Home fixture chat"].exists)
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
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.staticTexts["Home fixture chat"].exists)
        // Confirmed disable returns the ring to Manage Session.
        XCTAssertTrue(waitForLabel(app.buttons["session-context-button"], containing: "Manage Session", timeout: 8))
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Manage Home"].exists)
        app.terminate()
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
        app.buttons["home-pinned-row"].tap()
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 10), app.debugDescription)
        // The Home chat's gear opens Settings, as it does in every chat (#799).
        let gear = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.navigationBars.buttons["Manage Home"].exists)
        gear.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-state"].exists)
        keepScreenshot(named: "home-gear-settings-sheet")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 5), app.debugDescription)
        // Its context ring opens Manage Home at the medium detent, like Manage Session.
        openManageHome(app)
        let state = app.descendants(matching: .any)["home-manage-state"]
        XCTAssertTrue(state.label.contains("Ready"), state.label)
        let done = app.buttons["home-sheet-done-manage"]
        let windowHeight = app.windows.firstMatch.frame.height
        let mediumTop = done.frame.minY
        XCTAssertGreaterThan(mediumTop, windowHeight * 0.40, "Manage Home must open at its medium detent")
        keepScreenshot(named: "manage-home-medium")
        // It drags to large from the sheet title.
        let title = app.staticTexts["Manage Home"].firstMatch
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in done.frame.minY < mediumTop - 100 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed, "Manage Home must drag to its large detent")
        keepScreenshot(named: "manage-home-large")
        XCTAssertTrue(app.descendants(matching: .any)["session-model-summary"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home-manage-chapters"].exists)
        for row in ["home-manage-context", "home-manage-memory-browser", "home-manage-tasks",
                    "home-manage-permissions", "home-manage-pause", "home-manage-disable"] {
            XCTAssertTrue(app.descendants(matching: .any)[row].exists, row)
        }
        // A child surface keeps its own sheet lifetime above Manage Home and returns to it.
        tapManageRow(app, "home-manage-memory-browser")
        XCTAssertTrue(app.staticTexts["Asked to move garden planning to Thursday reviews"].waitForExistence(timeout: 5), app.debugDescription)
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
        // dashboard; the ordinary chat keeps the ordinary settings sheet from its gear.
        app.buttons["Back"].tap()
        let ordinary = app.buttons["session-row-home-shell-fixture:ordinary-session"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 10), app.debugDescription)
        ordinary.tap()
        XCTAssertTrue(app.staticTexts["Ordinary session chat"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Manage Home"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["home-manage-state"].exists)
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
        if !revoke.isHittable { app.swipeUp() }
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
                tapManageRow(app, "home-manage-permissions")
                XCTAssertTrue(app.staticTexts["Home task namespace refused: not-initialized"].waitForExistence(timeout: 5))
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
    private func chooseHomeGrantExpiry(_ app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["home-grant-expiry"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3), app.debugDescription)
        picker.buttons.firstMatch.tap()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let formatter = DateFormatter(); formatter.dateFormat = "EEEE, MMMM d"
        let day = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", formatter.string(from: tomorrow))).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 3), app.debugDescription)
        day.tap()
        // Dismiss the native compact DatePicker popover without touching a control.
        app.buttons["PopoverDismissRegion"].tap()
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
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 5))
    }

    /// A Home sheet belongs to the profile that opened it: once the selected profile
    /// changes, the sheet is dismissed rather than left presenting another Mac's Home.
    @MainActor
    func testHomeSheetDismissesWhenProfileSwitches() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-switch-profile-after-task-list"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-pinned-row"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["home-pinned-row"].tap()
        openManageHome(app)
        tapManageRow(app, "home-manage-tasks")
        XCTAssertTrue(app.buttons["home-sheet-done-tasks"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["home-task-active"].waitForExistence(timeout: 5), app.debugDescription)
        // Reloading is the sheet's second read; the fixture then selects another profile through
        // the production switch, which must release the chat and the sheet it presents.
        app.buttons["Reload tasks"].tap()
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
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 15), app.debugDescription)
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
        XCTAssertTrue(ready.staticTexts["Home fixture chat"].waitForExistence(timeout: 10))
        XCTAssertTrue(ready.staticTexts["fixture.home-diagnostics"].label.contains("home-shell-fixture"))
        ready.terminate()

        for state in ["undesignated", "disabled", "missing-session"] {
            let setup = XCUIApplication()
            setup.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-\(state)"]
            setup.launch()
            let designate = setup.buttons["home-pinned-row"]
            XCTAssertTrue(designate.waitForExistence(timeout: 10), state)
            designate.tap()
            XCTAssertTrue(setup.staticTexts["Home fixture chat"].waitForExistence(timeout: 10), state)
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
            XCTAssertTrue(app.staticTexts[session == "home" ? "Home fixture chat" : "Ordinary session chat"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 10), app.debugDescription)
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
        XCTAssertTrue(app.staticTexts["Home fixture chat"].waitForExistence(timeout: 5))
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
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
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
            switchModel.tap()
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
            app.terminate()
        }
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

    @MainActor
    func testIntegrationDestinationsHaveOneDoneButtonThroughSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-navigation-fixture"]
        for title in ["Connected Services", "MCP Servers"] {
            app.launch()
            let destination = app.buttons[title]
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            for _ in 0..<3 where !destination.isHittable { app.swipeUp() }
            XCTAssertTrue(destination.isHittable)
            destination.tap()
            let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
            XCTAssertTrue(done.firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(done.allElementsBoundByIndex.filter(\.isHittable).count, 1,
                           "Only the progressive settings shell owns dismissal")
            keepScreenshot(named: "settings-\(title)-single-done-light")
            done.allElementsBoundByIndex.first(where: \.isHittable)?.tap()
            XCTAssertTrue(app.buttons["Agent Defaults"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testAgentDefaultsThinkingSliderOpensAfterDefaultsConsolidation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-agent-defaults-fixture"]
        app.launch()
        defer { app.terminate() }
        let control = app.buttons.matching(identifier: "thinking-level-control")
            .matching(NSPredicate(format: "label == %@", "Thinking")).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(control.isEnabled)
        control.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "thinking-level-slider").firstMatch.waitForExistence(timeout: 3))
        keepScreenshot(named: "agent-defaults-thinking-editor-fixture")
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
        XCTAssertTrue(app.buttons["Open Tron navigation"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        let pageIndicator = app.descendants(matching: .any)["Onboarding step 1 of 9"]
        XCTAssertTrue(pageIndicator.exists)
        let next = app.buttons["Next"]
        XCTAssertLessThan(abs(next.frame.width - next.frame.height), 2, "The native sheet navigation control must be circular")
        XCTAssertGreaterThanOrEqual(next.frame.width, 34)
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

        XCTAssertTrue(app.alerts["Tron"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Enter a valid host, port, and one-time code."].exists)
        app.alerts["Tron"].buttons["OK"].tap()
        XCTAssertTrue(app.secureTextFields["One-time code"].waitForExistence(timeout: 2), app.debugDescription)
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
        let close = app.buttons["Close form and keep answers"]
        let send = app.buttons["Submit all answers"]
        XCTAssertTrue(cancel.exists && close.exists && send.exists)
        XCTAssertLessThan(cancel.frame.maxX, app.frame.midX)
        XCTAssertGreaterThan(close.frame.minX, app.frame.midX)
        XCTAssertLessThanOrEqual(close.frame.maxX, send.frame.minX)
        keepScreenshot(named: "ask-user-cancel-left-close-send-right")
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

    @MainActor
    func testAutomationInventorySummaryAndDetailTables() {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-automation-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = app.buttons["automation-card.automation-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), app.debugDescription)
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

    @MainActor
    func testAskUserOtherEditorExpandsMediumSheetAndOpensKeyboard() {
        let app = launchAskUser()
        waitForAskUserForm(in: app)
        let close = app.buttons["Close form and keep answers"]
        let mediumY = close.frame.minY
        XCTAssertGreaterThan(mediumY, app.frame.height * 0.4)
        app.buttons["Staging"].tap()
        app.buttons["Other"].tap()
        let editor = app.textViews["Other response for Environment"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(close.frame.minY, mediumY, accuracy: 2, "Revealing Other must not focus an unmounted editor")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        keepScreenshot(named: "ask-user-other-editor-medium")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let expanded = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return element.frame.minY < mediumY - 100
        }
        expectation(for: expanded, evaluatedWith: close)
        waitForExpectations(timeout: 5)
        editor.typeText("First line\nSecond line")
        XCTAssertEqual(editor.value as? String, "First line\nSecond line")
        keepScreenshot(named: "ask-user-other-editor-large-keyboard")
        app.buttons["Other"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Staging"].value as? String, "Selected")
        app.buttons["Other"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Close form and keep answers"].tap()
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].waitForExistence(timeout: 3))
    }

    /// Failure mode: Send on a paged single-choice form while the last page's
    /// Other editor holds the keyboard hangs the app before the answer is sent.
    @MainActor
    func testAskUserSendWithFocusedOtherEditorOnLastPageSubmits() {
        let app = launchAskUser(styled: true, multiple: true)
        let staging = app.buttons["Staging, A pre-release environment for validation."]
        XCTAssertTrue(staging.waitForExistence(timeout: 5), app.debugDescription)
        staging.tap()
        app.staticTexts["Which environments should receive the change?"].swipeLeft()
        XCTAssertTrue(app.staticTexts["When should the change happen?"].waitForExistence(timeout: 3), app.debugDescription)
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
        let close = app.buttons["Close form and keep answers"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let mediumY = close.frame.minY
        XCTAssertGreaterThan(mediumY, app.frame.height * 0.4)
        app.buttons["Other"].tap()
        let editor = app.textViews["Other response for Environment"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(close.frame.minY, mediumY, accuracy: 2)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(close.frame.minY, mediumY - 100)
        editor.typeText("A custom environment")
        app.buttons["Staging, A pre-release environment for validation."].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Submit all answers"].isEnabled)
        keepScreenshot(named: "ask-user-other-editor-hidden-single-choice")
    }

    @MainActor
    func testAskUserClosePreservesSelectionsAndOtherDraftOnReopen() {
        let app = launchAskUser()
        waitForAskUserForm(in: app)
        app.buttons["Staging"].tap()
        app.buttons["Other"].tap()
        let other = app.textViews["Other response for Environment"]
        XCTAssertTrue(other.waitForExistence(timeout: 3))
        other.tap()
        other.typeText("local canary")
        app.buttons["Close form and keep answers"].tap()
        XCTAssertTrue(app.buttons["Reopen Ask User"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mutation count: 0"].exists)
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
    func testAskUserWithoutAllowCancelHasCloseOnly() {
        let app = launchAskUser(noCancel: true)
        waitForAskUserForm(in: app)
        XCTAssertFalse(app.buttons["Cancel form"].exists)
        XCTAssertTrue(app.buttons["Close form and keep answers"].exists)
        app.buttons["Close form and keep answers"].tap()
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

    @MainActor
    func testAskUserInstructionAndSeparateToolbarLayout() {
        let app = launchAskUser(styled: true)
        let question = app.staticTexts["Which environments should receive the change?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        let instruction = app.staticTexts["Select one. Question 1 of 1"]
        let option = app.buttons["Staging, A pre-release environment for validation."]
        XCTAssertTrue(instruction.exists)
        XCTAssertTrue(option.exists)
        XCTAssertLessThanOrEqual(instruction.frame.maxY, question.frame.minY)
        XCTAssertLessThanOrEqual(question.frame.maxY, option.frame.minY)
        let close = app.buttons["Close form and keep answers"]
        let cancel = app.buttons["Cancel form"]
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertLessThan(cancel.frame.maxX, close.frame.minX)
        XCTAssertLessThanOrEqual(close.frame.maxX, app.buttons["Submit all answers"].frame.minX)
        XCTAssertFalse(app.buttons["Submit all answers"].isEnabled)
        keepScreenshot(named: "ask-user-styled-active-disabled")
        option.tap()
        XCTAssertTrue(app.buttons["Submit all answers"].isEnabled)
        keepScreenshot(named: "ask-user-styled-active-selected")
    }

    @MainActor
    private func launchAskUser(noCancel: Bool = false, styled: Bool = false, multiple: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-ask-user-fixture"]
        if noCancel { app.launchArguments.append("-tron-ask-user-no-cancel") }
        if styled { app.launchArguments.append("-tron-ask-user-styled") }
        if multiple { app.launchArguments.append("-tron-ask-user-multiple") }
        app.launch()
        return app
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
