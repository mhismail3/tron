import Foundation
import XCTest

final class TronSettingsListRefreshUITests: XCTestCase {
    @MainActor
    func testAdmittedCanonicalRefreshPreservesOpenDraftAndReopenUsesLatestSeed() throws {
        try refreshDraft(appearance: "light")
    }

    @MainActor
    func testAdmittedCanonicalRefreshPreservesOpenDraftAndReopenUsesLatestSeedDark() throws {
        try refreshDraft(appearance: "dark")
    }

    @MainActor
    private func refreshDraft(appearance: String) throws {
        continueAfterFailure = false
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("tron-list-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gate) }
        let app = XCUIApplication()
        app.launchArguments = ["-tron-settings-list-refresh-fixture", "-refresh-gate", gate.path, "-appearanceMode", appearance]
        app.launch()
        defer { app.terminate() }
        let refresh = app.buttons["Admit refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 30), app.debugDescription)
        refresh.tap()
        XCTAssertTrue(waitForFile(gate.appendingPathComponent("admitted")), "The canonical read must be admitted before editor entry")
        let row = app.buttons["Paths"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.buttons["Remove alpha"].waitForExistence(timeout: 15), app.debugDescription)
        let field = app.textFields["Value"]
        field.tap()
        field.typeText("local-draft")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["Remove local-draft"].waitForExistence(timeout: 15), app.debugDescription)
        try Data().write(to: gate.appendingPathComponent("release"))
        XCTAssertTrue(waitForFile(gate.appendingPathComponent("published")), "The AppModel canonical snapshot must publish while this draft is open")
        XCTAssertTrue(app.buttons["Remove local-draft"].exists, "An admitted canonical refresh must not replace unsaved edits: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["Remove alpha"].exists, "The complete original draft must survive")
        XCTAssertFalse(app.buttons["Remove canonical-latest"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "2030-open-draft-after-canonical-refresh-\(appearance)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars.buttons["Done"].tap()
        row.tap()
        XCTAssertTrue(app.buttons["Remove canonical-latest"].waitForExistence(timeout: 15), "A new presentation must seed the latest accepted canonical value: \(app.debugDescription)")
        XCTAssertFalse(app.buttons["Remove local-draft"].exists)
        XCTAssertFalse(app.buttons["Remove alpha"].exists)
    }

    private func waitForFile(_ url: URL) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: url.path)
        }, object: nil)
        return XCTWaiter.wait(for: [ready], timeout: 15) == .completed
    }
}
