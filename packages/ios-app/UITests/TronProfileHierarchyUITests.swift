import XCTest

/// Actual simulator captures of the shipping Profile sheet, not an alternate preview UI.
/// All data is synthetic. Existing Home mutation journeys keep their default fixture.
final class TronProfileHierarchyUITests: XCTestCase {
    @MainActor
    func testNativeHierarchyReviewMatrix() {
        continueAfterFailure = false
        let variants = [("large", "UICTContentSizeCategoryL"),
                        ("xxl", "UICTContentSizeCategoryXXL"),
                        ("xxxl", "UICTContentSizeCategoryXXXL")]
        for theme in ["light", "dark"] {
            var previousHeight: CGFloat = 0
            for (size, category) in variants {
                let height = review(theme: theme, size: size, category: category)
                XCTAssertGreaterThan(height, previousHeight, "The actual native row grows at each Dynamic Type size")
                previousHeight = height
                let measured = XCTAttachment(string: "theme=\(theme) size=\(size) nativeRowHeight=\(height)")
                measured.name = "native-profile-\(theme)-\(size)-measurement"
                measured.lifetime = .keepAlways
                add(measured)
            }
        }
    }

    @MainActor private func review(theme: String, size: String, category: String) -> CGFloat {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-profile-hierarchy",
                               "-UIPreferredContentSizeCategoryName", category]
        if theme == "dark" { app.launchArguments.append("-home-dark") }
        app.launch()
        defer { app.terminate() }
        let prefix = "native-profile-\(theme)-\(size)"
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        let ring = app.buttons["session-context-button"]
        XCTAssertTrue(wait(ring, "enabled == true"))
        ring.tap()
        XCTAssertTrue(element(app, "home-manage-state").waitForExistence(timeout: 8))
        let profile = element(app, "home-manage-profile")
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        XCTAssertTrue(element(app, "home-profile-items").waitForExistence(timeout: 8))
        expand(app, done: "home-sheet-done-profile")
        let life = element(app, "home-profile-item-profile-hierarchy-example-1")
        XCTAssertTrue(life.waitForExistence(timeout: 5))
        let rowHeight = life.frame.height
        life.tap()
        XCTAssertTrue(element(app, "home-profile-item-detail").waitForExistence(timeout: 5))
        // Positive control: the same edit identifier exists on a writable-placement item.
        XCTAssertTrue(element(app, "home-profile-item-edit").exists)
        app.buttons["home-sheet-done-profile-item"].tap()
        XCTAssertTrue(element(app, "home-profile-items").waitForExistence(timeout: 5))

        // Overlapping native viewports retain every section for visual sign-off.
        // The terminal note is the fixture's inactive row, not a guessed scroll count.
        let inactive = element(app, "home-profile-item-3f3264c8-5ad4-44bd-853b-c0b3a2008196")
        keep("\(prefix)-00")
        for page in 1...8 {
            if inactive.exists && inactive.isHittable { break }
            app.swipeUp(velocity: .slow)
            keep(String(format: "%@-%02d", prefix, page))
        }
        XCTAssertTrue(inactive.isHittable, "The bounded review reached the inactive note")

        // Historical organization can be read but cannot be edited or confirmed.
        let prior = element(app, "home-profile-item-profile-hierarchy-example-6")
        for _ in 0..<3 where !prior.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(prior.isHittable)
        prior.tap()
        XCTAssertTrue(element(app, "home-profile-item-detail").waitForExistence(timeout: 5))
        expand(app, done: "home-sheet-done-profile-item")
        XCTAssertFalse(element(app, "home-profile-item-confirm").exists)
        XCTAssertFalse(element(app, "home-profile-item-edit").exists)
        XCTAssertFalse(element(app, "home-profile-item-retire").exists)
        keep("\(prefix)-prior-readonly")
        return rowHeight
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func expand(_ app: XCUIApplication, done id: String) {
        let done = app.buttons[id].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        guard done.frame.minY > 120 else { return }
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        // Home's scroll view can scroll while still at medium. Drag the actual
        // navigation title, between the toolbar controls, instead of its content.
        origin.withOffset(CGVector(dx: window.frame.midX, dy: done.frame.midY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: window.frame.midX, dy: 20)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        // CGRect's minY is a Swift computation, not a KVC property for a string predicate.
        let expanded = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in done.frame.minY < 120 }, object: nil)], timeout: 8) == .completed
        if !expanded { keep("failed-expand-\(id)") }
        XCTAssertTrue(expanded, "\(id): \(done.frame)")
    }

    private func wait(_ element: XCUIElement, _ predicate: String) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)],
                      timeout: 8) == .completed
    }

    @MainActor private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
