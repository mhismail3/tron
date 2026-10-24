import CryptoKit
import XCTest

/// Real app processes and actual UUID-scoped files, through the production
/// SnapshotCache/AppModel owners. Fixture reports are file/model observations,
/// not persistence substitutes, private actor counters or passed flags.
final class SnapshotCachePersistenceContractTests: XCTestCase {
    private enum Failure: Error { case missing(String), malformedReport }
    private let firstID = "fixture/profile:first"
    private let secondID = "fixture/profile:second"

    @MainActor
    private func launch(_ app: XCUIApplication, mode: String, token: String) {
        app.launchArguments = ["-tron-snapshot-cache-fixture", "-snapshot-cache-mode", mode,
            "-snapshot-cache-token", token, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
    }

    @MainActor
    private func require(_ app: XCUIApplication, _ id: String, label: String) throws -> XCUIElement {
        let element = app.staticTexts[id]
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        let result = XCTWaiter.wait(for: [expected], timeout: 10)
        XCTAssertEqual(result, .completed, "Expected \(id)=\(label); actual \(element.exists ? element.label : "<missing>")")
        guard result == .completed else { throw Failure.missing(id) }
        return element
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ id: String) throws {
        let button = app.buttons[id]
        guard button.waitForExistence(timeout: 5) else { XCTFail("Missing action \(id)"); throw Failure.missing(id) }
        button.tap()
    }

    @MainActor
    private func inspect(_ app: XCUIApplication) throws -> [String: Any] {
        try tap(app, "cache.inspect")
        let text = app.staticTexts["cache.file-report"]
        guard text.waitForExistence(timeout: 5), let data = text.label.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Invalid actual-file report"); throw Failure.malformedReport
        }
        return object
    }

    private func filename(_ profileID: String) -> String {
        SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func document(_ report: [String: Any], profileID: String) throws -> [String: Any] {
        let rows = report["documents"] as? [[String: Any]] ?? []
        return try XCTUnwrap(rows.first { $0["file"] as? String == filename(profileID) })
    }

    @MainActor
    private func cleanup(_ app: XCUIApplication) {
        if app.state == .runningForeground, app.buttons["cache.cleanup"].exists {
            app.buttons["cache.cleanup"].tap()
            _ = try? require(app, "cache.phase", label: "cleaned")
        }
        app.terminate()
    }

    @MainActor
    func testSummaryOnlyArchiveCountSurvivesColdProcessRelaunch() throws {
        let app = XCUIApplication(), token = UUID().uuidString
        defer { cleanup(app) }
        launch(app, mode: "live", token: token)
        _ = try require(app, "cache.phase", label: "ready")
        _ = try require(app, "cache.runtime-transcript", label: "present")
        let firstPID = app.staticTexts["cache.pid"].label
        let stored = try document(inspect(app), profileID: firstID)
        XCTAssertEqual(stored["version"] as? Int, 4)
        XCTAssertEqual(stored["ids"] as? [String], ["cache-live"])
        XCTAssertEqual(stored["archivedCount"] as? Int, 7)
        XCTAssertEqual(stored["hasTranscript"] as? Bool, false)
        XCTAssertEqual(stored["hasTranscriptKey"] as? Bool, false)
        app.terminate() // intentionally retain only this UUID root for the next process
        launch(app, mode: "restore", token: token)
        _ = try require(app, "cache.phase", label: "ready")
        _ = try require(app, "cache.catalog", label: "Before summary")
        _ = try require(app, "cache.catalog-archive", label: "7")
        XCTAssertNotEqual(app.staticTexts["cache.pid"].label, firstPID)
        XCTAssertEqual(try document(inspect(app), profileID: firstID)["hasTranscript"] as? Bool, false)
    }

    @MainActor
    func testReadableVersionsAndInvalidOrOversizedEnvelopesFailClosed() throws {
        for mode in ["v3", "v4", "future", "corrupt", "oversized"] {
            let app = XCUIApplication()
            defer { cleanup(app) }
            launch(app, mode: mode, token: UUID().uuidString)
            _ = try require(app, "cache.phase", label: "ready")
            let valid = mode == "v3" || mode == "v4"
            _ = try require(app, "cache.catalog", label: valid ? "Before summary" : "<none>")
            let report = try inspect(app)
            XCTAssertEqual(report["firstExists"] as? Bool, valid)
            if valid {
                let stored = try document(report, profileID: firstID)
                XCTAssertEqual(stored["version"] as? Int, mode == "v3" ? 3 : 4)
            } else {
                XCTAssertEqual((report["documents"] as? [[String: Any]])?.count, 0)
            }
        }
    }

    @MainActor
    func testGenerationFencesDigestSeparationAndRemovalTombstone() throws {
        let app = XCUIApplication()
        defer { cleanup(app) }
        launch(app, mode: "generations", token: UUID().uuidString)
        _ = try require(app, "cache.phase", label: "generation-ready")
        _ = try require(app, "cache.kernel-loads", label: "Generation winner|Other profile")
        let report = try inspect(app)
        XCTAssertEqual((report["documents"] as? [[String: Any]])?.count, 2)
        let first = try document(report, profileID: firstID)
        let second = try document(report, profileID: secondID)
        XCTAssertEqual(first["names"] as? [String], ["Generation winner"])
        XCTAssertEqual(first["ids"] as? [String], ["cache-live"], "Archived row must not be persisted")
        XCTAssertEqual(first["archivedCount"] as? Int, 7)
        XCTAssertEqual(second["names"] as? [String], ["Other profile"])
        try tap(app, "cache.forget")
        _ = try require(app, "cache.phase", label: "forgotten")
        let after = try inspect(app)
        XCTAssertEqual(after["firstExists"] as? Bool, false)
        XCTAssertEqual((after["documents"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try document(after, profileID: secondID)["names"] as? [String], ["Other profile"])
    }

    @MainActor
    private func pendingSummary(_ app: XCUIApplication) throws {
        _ = try require(app, "cache.phase", label: "ready")
        XCTAssertEqual(try document(inspect(app), profileID: firstID)["names"] as? [String], ["Before summary"])
        try tap(app, "cache.summary")
        _ = try require(app, "cache.catalog", label: "After summary")
        _ = try require(app, "cache.delay", label: "held")
    }

    @MainActor
    func testBackgroundAPICompletesOnlyAfterItsRealCacheWrite() throws {
        let app = XCUIApplication()
        defer { cleanup(app) }
        launch(app, mode: "live", token: UUID().uuidString)
        try pendingSummary(app)
        try tap(app, "cache.background")
        _ = try require(app, "cache.save", label: "held")
        _ = try require(app, "cache.completion", label: "pending")
        XCTAssertEqual(try document(inspect(app), profileID: firstID)["names"] as? [String], ["Before summary"])
        try tap(app, "cache.release")
        _ = try require(app, "cache.completion", label: "done")
        XCTAssertEqual(try document(inspect(app), profileID: firstID)["names"] as? [String], ["After summary"])
        try tap(app, "cache.forget")
        _ = try require(app, "cache.phase", label: "forgotten")
        XCTAssertEqual(try inspect(app)["firstExists"] as? Bool, false)
    }

    @MainActor
    func testProfileRetirementDrainsTrailingCheckpointBeforeSuccessor() throws {
        let app = XCUIApplication()
        defer { cleanup(app) }
        launch(app, mode: "live", token: UUID().uuidString)
        try pendingSummary(app)
        try tap(app, "cache.switch")
        _ = try require(app, "cache.save", label: "held")
        _ = try require(app, "cache.completion", label: "pending")
        try tap(app, "cache.release")
        _ = try require(app, "cache.completion", label: "done")
        _ = try require(app, "cache.profile", label: secondID)
        XCTAssertEqual(try document(inspect(app), profileID: firstID)["names"] as? [String], ["After summary"])
    }
}
