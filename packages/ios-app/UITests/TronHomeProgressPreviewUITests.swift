import XCTest

/// Screenshot-only native previews for approval; not regression acceptance.
@MainActor final class TronHomeProgressPreviewUITests: XCTestCase {
    func testWorkingIndicatorPreviews() throws {
        for theme in ["emerald", "burgundy"] {
            for mode in ["light", "dark"] {
                let app = XCUIApplication()
                app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready",
                    "-home-phase-active", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                    "-themeColor", theme] + (mode == "dark" ? ["-home-dark"] : [])
                app.launch()
                let button = app.buttons["dashboard.menu"]
                let working = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND value == 'Working'"), object: button)
                guard XCTWaiter.wait(for: [working], timeout: 15) == .completed else {
                    app.terminate()
                    throw NSError(domain: "HomeProgressPreview", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Dashboard did not reach Working for \(theme) \(mode)"])
                }
                let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                attachment.name = "working-\(theme)-\(mode)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
