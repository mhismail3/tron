import XCTest

/// Native design captures, not behavioral acceptance or golden regression tests.
/// One simulator run captures all four appearance/type variants of each surface.
@MainActor final class TronProfileHierarchyDesignPreviewUITests: XCTestCase {
    func testCaptureProfileHierarchyDesign() throws {
        for dark in [false, true] {
            for xxl in [false, true] {
                for page in ["root", "engineering", "inferred", "triage"] {
                    let app = XCUIApplication()
                    app.launchArguments = ["-tron-profile-hierarchy-design", "-profile-design-page", page,
                        "-themeColor", "emerald", "-fontFamily", "system", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                        + (dark ? ["-profile-design-dark"] : [])
                        + (xxl ? ["-profile-design-xxl"] : [])
                    app.launch()
                    let scroll = app.scrollViews["profile-design-scroll"].firstMatch
                    guard scroll.waitForExistence(timeout: 15) else {
                        app.terminate()
                        throw NSError(domain: "ProfileHierarchyDesign", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Preview failed to mount: \(page)"])
                    }
                    let name = "\(page)-\(dark ? "dark" : "light")-\(xxl ? "xxl" : "normal")"
                    keep(app, name)
                    if page == "root" || page == "triage" || xxl {
                        scroll.swipeUp()
                        keep(app, "\(name)-lower")
                    }
                    app.terminate()
                }
            }
        }
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }
}
