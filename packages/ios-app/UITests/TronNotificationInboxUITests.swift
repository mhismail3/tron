import UIKit
import XCTest

final class TronNotificationInboxUITests: XCTestCase {
    private let deliver = "com.tron.hosted.notification-inbox.deliver"
    private let readNewest = "com.tron.hosted.notification-inbox.read-newest"

    @MainActor func testSheetFollowsGatewayLiveWithoutOfflineRowOrPullToRefresh() throws {
        continueAfterFailure = false
        let app = launch("mixed"); defer { app.terminate() }
        openInbox(app)

        let ask = row(app, "inbox-row-ask")
        let finished = row(app, "inbox-row-finished")
        XCTAssertTrue(ask.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(ask.value as? String, "Unread")
        XCTAssertTrue(finished.exists)
        XCTAssertTrue(waitFor(ask, label: "Release checklist, Input needed, "), ask.label)
        XCTAssertTrue(ask.label.hasSuffix(", Studio Mac"), ask.label)
        assertNoConnectionRow(app)
        try capture(app, "unread")

        selectFilter(app, "All")
        let home = row(app, "inbox-row-home")
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(home.value as? String, "Read")
        XCTAssertTrue(home.label.hasPrefix("Home, Agent finished, "), home.label)
        XCTAssertTrue(hasSurface(app, home, threshold: 3), "a read row sits on its glass surface, not bare on the sheet")
        XCTAssertTrue(hasSurface(app, finished), "an unread row sits on its glass surface")
        XCTAssertTrue(isTinted(app, finished, comparedWith: home), "an unread row carries the accent tint on its glass")
        assertNoConnectionRow(app)
        try capture(app, "all")

        let filter = app.buttons["Unread"]
        let start = home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
        XCTAssertEqual(app.activityIndicators.count, 0, "a pull starts no refresh spinner: \(app.debugDescription)")
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "the sheet stays open after the pull")

        post(deliver)
        let live = row(app, "inbox-row-live-1")
        XCTAssertTrue(live.waitForExistence(timeout: 20), "the new notification never appeared: \(app.debugDescription)")
        XCTAssertEqual(live.value as? String, "Unread")
        XCTAssertTrue(waitFor(live, value: "Unread"))
        XCTAssertTrue(hasSurface(app, live))
        XCTAssertTrue(isTinted(app, live, comparedWith: home))
        try capture(app, "all-live-delivered")

        post(readNewest)
        XCTAssertTrue(waitFor(live, value: "Read"), "the read never reached the open sheet: \(live.debugDescription)")
        XCTAssertTrue(hasSurface(app, live, threshold: 3), "the read row keeps its glass surface")
        XCTAssertFalse(isTinted(app, live, comparedWith: home), "the read row lost its tint")

        let markRead = app.buttons["Mark all notifications read"]
        XCTAssertTrue(markRead.isEnabled)
        markRead.tap()
        XCTAssertTrue(waitFor(ask, value: "Read"), ask.debugDescription)
        XCTAssertTrue(waitFor(finished, value: "Read"), finished.debugDescription)
        XCTAssertTrue(hasSurface(app, finished, threshold: 3))
        XCTAssertFalse(isTinted(app, finished, comparedWith: home))
        assertNoConnectionRow(app)
    }

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

    @MainActor func testMarkReadOnUnreadSettlesOnceWhileTheRefreshRuns() throws {
        continueAfterFailure = false
        let app = launch("mixed", arguments: ["-notification-inbox-list-latency"]); defer { app.terminate() }
        openInbox(app)
        let ask = row(app, "inbox-row-ask")
        XCTAssertTrue(ask.waitForExistence(timeout: 20), app.debugDescription)
        let pulse = app.descendants(matching: .any)["sheet-loading"]
        XCTAssertTrue(waitFor { !pulse.exists }, "the first load never settled: \(app.debugDescription)")
        try capture(app, "unread-before-mark-read")

        let filter = app.buttons["Unread"]
        let empty = app.staticTexts["No unread notifications"]
        app.buttons["Mark all notifications read"].tap()
        let observeUntil = Date().addingTimeInterval(5)
        var transitions: [String] = []
        while Date() < observeUntil {
            let state = pulse.exists ? "pulse" : !filter.exists ? "hidden"
                : empty.exists ? "empty" : ask.exists ? "rows" : "blank"
            guard transitions.last != state else { continue }
            transitions.append(state)
            if state != "empty" && state != "rows" { try capture(app, "unread-after-mark-read-\(transitions.count)-\(state)") }
        }
        XCTAssertEqual(Array(transitions.drop { $0 == "rows" }), ["empty"],
                       "Mark Read must settle the Unread list once, not reload it: \(transitions)")
        XCTAssertFalse(ask.exists)
        try capture(app, "unread-after-mark-read-settled")
    }

    @MainActor private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 20) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                       timeout: timeout) == .completed
    }

    @MainActor private func launch(_ scenario: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-notification-inbox-fixture", "-notification-inbox-scenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        return app
    }

    @MainActor private func openInbox(_ app: XCUIApplication) {
        let bell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open notifications'")).firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 30), "the Settings bell never appeared: \(app.debugDescription)")
        bell.tap()
        XCTAssertTrue(app.buttons["Unread"].waitForExistence(timeout: 10), app.debugDescription)
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

    @MainActor private func assertNoConnectionRow(_ app: XCUIApplication) {
        let offline = NSPredicate(format: "label CONTAINS[c] 'offline' OR label CONTAINS[c] 'could not load' OR label == 'Retry'")
        XCTAssertEqual(app.descendants(matching: .any).matching(offline).count, 0, app.debugDescription)
    }

    @MainActor private func hasSurface(_ app: XCUIApplication, _ element: XCUIElement, threshold: Int = 6) -> Bool {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return false }
        let scale = CGFloat(image.width) / app.frame.width
        let frame = element.frame
        guard let inside = pixel(image, CGPoint(x: (frame.maxX - 8) * scale, y: frame.midY * scale)),
              let outside = pixel(image, CGPoint(x: (frame.maxX + 4) * scale, y: frame.midY * scale)) else { return false }
        let measuredDistance = distance(inside, outside)
        print("INBOX_SURFACE \(element.identifier) inside=\(inside) outside=\(outside) distance=\(measuredDistance) threshold=\(threshold)")
        return measuredDistance > threshold
    }

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
