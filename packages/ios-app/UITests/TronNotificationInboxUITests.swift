import UIKit
import XCTest

/// The Notifications sheet opened from the Settings bell (#938). The fixture
/// scripts only the selected Gateway's inbox; a second paired Mac is offline.
/// The test changes the Gateway's inbox while the sheet is open through Darwin
/// notifications the fixture observes, so every change reaches the app as the
/// Gateway's own `notification.inbox.changed` event.
final class TronNotificationInboxUITests: XCTestCase {
    private let deliver = "com.tron.hosted.notification-inbox.deliver"
    private let readNewest = "com.tron.hosted.notification-inbox.read-newest"

    /// With a paired Mac offline the sheet has no connection row of its own;
    /// a pull neither refreshes nor shows a spinner; a new alert and a read on
    /// another device change the open sheet live; every row sits on the shared
    /// Liquid Glass row surface, clear when read and accent-tinted when unread.
    @MainActor func testSheetFollowsGatewayLiveWithoutOfflineRowOrPullToRefresh() throws {
        continueAfterFailure = false
        let app = launch("mixed"); defer { app.terminate() }
        openInbox(app)

        let ask = row(app, "inbox-row-ask")
        let finished = row(app, "inbox-row-finished")
        XCTAssertTrue(ask.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(ask.value as? String, "Unread")
        XCTAssertTrue(finished.exists)
        // Titled by its chat from the catalog; the kind is the icon, said once.
        XCTAssertTrue(waitFor(ask, label: "Release checklist, Input needed, "), ask.label)
        // Two Macs are paired, so each row names its Gateway once.
        XCTAssertTrue(ask.label.hasSuffix(", Studio Mac"), ask.label)
        assertNoConnectionRow(app)
        try capture(app, "unread")

        // All mixes read and unread rows: each is its own glass row (#956),
        // clear when read and tinted when unread.
        selectFilter(app, "All")
        let home = row(app, "inbox-row-home")
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(home.value as? String, "Read")
        XCTAssertTrue(home.label.hasPrefix("Home, Agent finished, "), home.label)
        XCTAssertTrue(hasSurface(app, home), "a read row sits on its glass surface, not bare on the sheet")
        XCTAssertTrue(hasSurface(app, finished), "an unread row sits on its glass surface")
        XCTAssertTrue(isTinted(app, finished, comparedWith: home), "an unread row carries the accent tint on its glass")
        assertNoConnectionRow(app)
        try capture(app, "all")

        // A pull is not a refresh: no spinner, no list read, the sheet stays.
        let filter = app.buttons["Unread"]
        let start = home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
        XCTAssertEqual(app.activityIndicators.count, 0, "a pull starts no refresh spinner: \(app.debugDescription)")
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "the sheet stays open after the pull")

        // A new alert appears while the sheet is open, unread and tinted.
        post(deliver)
        let live = row(app, "inbox-row-live-1")
        XCTAssertTrue(live.waitForExistence(timeout: 20), "the new notification never appeared: \(app.debugDescription)")
        XCTAssertEqual(live.value as? String, "Unread")
        XCTAssertTrue(waitFor(live, value: "Unread"))
        XCTAssertTrue(hasSurface(app, live))
        XCTAssertTrue(isTinted(app, live, comparedWith: home))
        try capture(app, "all-live-delivered")

        // Read on another device: the same row turns read and clear in place.
        post(readNewest)
        XCTAssertTrue(waitFor(live, value: "Read"), "the read never reached the open sheet: \(live.debugDescription)")
        XCTAssertTrue(hasSurface(app, live), "the read row keeps its glass surface")
        XCTAssertFalse(isTinted(app, live, comparedWith: home), "the read row lost its tint")

        // Mark Read clears every remaining unread row in place.
        let markRead = app.buttons["Mark all notifications read"]
        XCTAssertTrue(markRead.isEnabled)
        markRead.tap()
        XCTAssertTrue(waitFor(ask, value: "Read"), ask.debugDescription)
        XCTAssertTrue(waitFor(finished, value: "Read"), finished.debugDescription)
        XCTAssertTrue(hasSurface(app, finished))
        XCTAssertFalse(isTinted(app, finished, comparedWith: home))
        assertNoConnectionRow(app)
    }

    /// The empty Unread and All states with a paired Mac offline: the shared
    /// empty state, no connection row, and a live first alert.
    @MainActor func testEmptyInboxShowsEmptyStateAndReceivesFirstAlertLive() throws {
        continueAfterFailure = false
        let app = launch("empty"); defer { app.terminate() }
        openInbox(app)
        XCTAssertTrue(app.staticTexts["No unread notifications"].waitForExistence(timeout: 20), app.debugDescription)
        assertNoConnectionRow(app)
        try capture(app, "empty-unread")
        selectFilter(app, "All")
        XCTAssertTrue(app.staticTexts["No notifications yet"].waitForExistence(timeout: 10), app.debugDescription)
        try capture(app, "empty-all")

        post(deliver)
        let live = row(app, "inbox-row-live-1")
        XCTAssertTrue(live.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.staticTexts["No notifications yet"].exists)
    }

    // MARK: - Helpers

    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-notification-inbox-fixture", "-notification-inbox-scenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func openInbox(_ app: XCUIApplication) {
        let bell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open notifications'")).firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 30), "the Settings bell never appeared: \(app.debugDescription)")
        bell.tap()
        XCTAssertTrue(app.buttons["Unread"].waitForExistence(timeout: 10), app.debugDescription)
        // Expand to the large detent so every seeded row is on screen.
        let title = app.staticTexts["Notifications"]
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
    }

    @MainActor private func selectFilter(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.tap()
    }

    @MainActor private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons["notifications.row.\(id)"]
    }

    @MainActor private func waitFor(_ element: XCUIElement, value: String) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)],
            timeout: 20
        ) == .completed
    }

    @MainActor private func waitFor(_ element: XCUIElement, label prefix: String) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: element)],
            timeout: 20
        ) == .completed
    }

    /// The sheet never renders its own connection treatment, however long the
    /// offline Mac's inbox read has been failing.
    @MainActor private func assertNoConnectionRow(_ app: XCUIApplication) {
        let offline = NSPredicate(format: "label CONTAINS[c] 'offline' OR label CONTAINS[c] 'could not load' OR label == 'Retry'")
        XCTAssertEqual(app.descendants(matching: .any).matching(offline).count, 0, app.debugDescription)
    }

    /// Whether a row has its own surface: one pixel inside the row's trailing
    /// padding against one just outside it, close enough that the blurred
    /// sheet behind both is the same. A bare row on the sheet matches.
    @MainActor private func hasSurface(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return false }
        let scale = CGFloat(image.width) / app.frame.width
        let frame = element.frame
        guard let inside = pixel(image, CGPoint(x: (frame.maxX - 8) * scale, y: frame.midY * scale)),
              let outside = pixel(image, CGPoint(x: (frame.maxX + 4) * scale, y: frame.midY * scale)) else { return false }
        return distance(inside, outside) > 6
    }

    /// Whether a row's surface carries the accent tint: the same point in its
    /// trailing padding against a read (clear glass) row's.
    @MainActor private func isTinted(_ app: XCUIApplication, _ element: XCUIElement, comparedWith clear: XCUIElement) -> Bool {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return false }
        let scale = CGFloat(image.width) / app.frame.width
        guard let row = pixel(image, CGPoint(x: (element.frame.maxX - 8) * scale, y: element.frame.midY * scale)),
              let reference = pixel(image, CGPoint(x: (clear.frame.maxX - 8) * scale, y: clear.frame.midY * scale))
        else { return false }
        return distance(row, reference) > 6
    }

    private func distance(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    private func pixel(_ image: CGImage, _ point: CGPoint) -> [Int]? {
        guard let crop = image.cropping(to: CGRect(x: Int(point.x), y: Int(point.y), width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map(Int.init)
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) throws {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "938-\(name)"; attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["TRON_INBOX_CAPTURE_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try image.pngRepresentation.write(to: root.appendingPathComponent("\(name).png"), options: .atomic)
        }
    }
}
