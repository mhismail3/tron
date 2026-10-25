import XCTest

/// Capture-only design review using real Gateway presentation over synthetic stores.
/// Not behavioral acceptance; the external payload is generated from the checkpoint's Gateway.
final class TronSettingsMoveTwoPreviewUITests: XCTestCase {
    @MainActor func testCaptureRows() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TRON_MOVE_TWO_PAYLOAD_PATH"] else { throw XCTSkip("Capture payload not supplied") }
        let payload = try String(contentsOfFile: path, encoding: .utf8)
        let appearance = environment["TRON_MOVE_TWO_APPEARANCE"] ?? "light"
        let size = environment["TRON_MOVE_TWO_SIZE"] ?? "normal"
        let stage = environment["TRON_MOVE_TWO_STAGE"] ?? "review"
        let decoded = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
        for (kind, section) in [("global", "root"), ("global", "model"), ("global", "workers"),
                                ("global", "context"), ("global", "run"), ("global", "tools"),
                                ("global", "sources"), ("session", "run"), ("project", "run")] {
            if section != "root", let resolution = decoded[kind] as? [String: Any],
               let keys = resolution["keys"] as? [[String: Any]], !keys.contains(where: { $0["group"] as? String == section }) { continue }
            let app = XCUIApplication()
            app.launchArguments = ["-tron-settings-renderer-fixture"]
            if appearance == "dark" { app.launchArguments.append("-settings-renderer-dark") }
            if size == "xxxl" { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] }
            app.launchEnvironment["TRON_MOVE_TWO_PAYLOAD"] = payload
            app.launchEnvironment["TRON_MOVE_TWO_TARGET"] = kind
            app.launchEnvironment["TRON_MOVE_TWO_SECTION"] = section
            app.launch()
            guard app.navigationBars.firstMatch.waitForExistence(timeout: 15) else {
                XCTFail("Capture did not open: \(app.debugDescription)"); app.terminate(); return
            }
            // Allow the fixture connection and settings snapshot to publish before capture.
            _ = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings-row-' OR identifier BEGINSWITH 'settings-section-'"))
                .firstMatch.waitForExistence(timeout: 15)
            for page in 0..<3 {
                let name = "\(stage)-\(kind)-\(section)-\(appearance)-\(size)-\(page)"
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
                app.swipeUp()
            }
            app.terminate()
        }
    }
}
