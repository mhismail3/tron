import Network
import XCTest
import UIKit

@MainActor final class TronDisplayDocumentThemeUITests: XCTestCase {
    func testSiblingMarkdownImageAndUnavailableTargets() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-tron-chat-display-fixture", "-display-document-theme", "-display-document-images",
                                   "-display-document-home", "-themeColor", "burgundy"]
                + (mode == "light" ? ["-polish-light"] : [])
            app.launch()
            defer { app.terminate() }
            let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home audit report")).firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 20), app.debugDescription)
            chip.tap()
            let image = app.images["Preview"].firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertGreaterThan(image.frame.width, 100, "Sibling capture is readable, not an icon")
            let frame = image.frame.insetBy(dx: 8, dy: 8)
            let top = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 3)
            let bottom = CGRect(x: frame.minX, y: frame.maxY - frame.height / 3, width: frame.width, height: frame.height / 3)
            let red = chroma(app, top), blue = chroma(app, bottom)
            XCTAssertGreaterThan(red[0], red[2] + 0.5, "Actual sibling PNG pixels render red above blue")
            XCTAssertGreaterThan(blue[2], blue[0] + 0.5, "Actual sibling PNG pixels render red above blue")
            XCTAssertTrue(app.staticTexts["Missing: image unavailable."].firstMatch.exists, app.debugDescription)
            XCTAssertTrue(app.staticTexts["Outside: image unavailable."].firstMatch.exists, app.debugDescription)
            capture(app, "2027-markdown-images-\(mode)")
            app.buttons["Done"].tap()
            XCTAssertTrue(chip.isHittable, "The reader remains dismissible")
            app.terminate()
        }
    }

    func testHomeAndSessionMarkdownFollowPrimaryTheme() {
        for theme in ["burgundy", "oliveGold"] {
            for mode in ["light", "dark"] {
                for home in [true, false] {
                    let app = open(theme: theme, mode: mode, home: home)
                    let title = app.navigationBars.staticTexts[home ? "Home audit report" : "Session summary"].firstMatch
                    let link = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Navigation evidence'")).firstMatch
                    XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
                    capture(app, "regression-\(theme)-\(mode)-\(home ? "home" : "session")")
                    for (name, frame) in [("title", title.frame), ("Done", app.buttons["Done"].frame), ("Markdown link", link.frame)] {
                        let hue = chroma(app, frame)
                        if theme == "burgundy" {
                            XCTAssertGreaterThan(hue[0], hue[1] + 0.5, "\(name) must be burgundy: \(hue)")
                            XCTAssertGreaterThan(hue[0], hue[2] + 0.15, "\(name) must be burgundy: \(hue)")
                        } else {
                            XCTAssertGreaterThan(hue[0], hue[2] + 0.5, "\(name) must be olive gold: \(hue)")
                            XCTAssertGreaterThan(hue[1], hue[2] + 0.5, "\(name) must be olive gold: \(hue)")
                        }
                    }
                    app.buttons["Done"].tap()
                    XCTAssertFalse(title.exists, "Done dismisses the document")
                    app.terminate()
                }
            }
        }
    }

    func testMountedReaderUpdatesThemeAndAppearance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-display-document-updates", "-themeColor", "burgundy"]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["Open theme-change reader"]
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
        let link = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Navigation evidence'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        let title = app.navigationBars.staticTexts["Theme change reader"].firstMatch
        let originalFrame = link.frame
        for olive in [false, true] {
            if olive { app.buttons["Switch reader theme"].tap() }
            for appearanceChange in [false, true] {
                if appearanceChange { app.buttons["Switch reader appearance"].tap() }
                for frame in [title.frame, app.buttons["Done"].frame, link.frame] {
                    let hue = chroma(app, frame)
                    XCTAssertGreaterThan(hue[0], hue[2] + (olive ? 0.5 : 0.15), "Mounted reader adopts the new theme: \(hue)")
                    if olive { XCTAssertGreaterThan(hue[1], hue[2] + 0.5) }
                    else { XCTAssertGreaterThan(hue[0], hue[1] + 0.5) }
                }
                XCTAssertEqual(link.frame.minY, originalFrame.minY, accuracy: 1, "Theme changes preserve reader layout")
            }
        }
        capture(app, "mounted-reader-theme-appearance-updated")
        app.buttons["Done"].tap()
        XCTAssertTrue(open.isHittable, "The same sheet remains dismissible")
    }

    func testAuthoredHTMLKeepsLinkWarningAndErrorColors() {
        for mode in ["light", "dark"] {
            let app = open(theme: "burgundy", mode: mode, home: true, html: true)
            defer { app.terminate() }
            let link = app.links["Authored cyan link"].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
            let cyan = chroma(app, link.frame)
            XCTAssertGreaterThan(cyan[1], cyan[0] + 0.5)
            XCTAssertGreaterThan(cyan[2], cyan[0] + 0.5)
            for label in ["Semantic warning", "Semantic error"] {
                let text = app.staticTexts[label].firstMatch
                XCTAssertTrue(text.exists, app.debugDescription)
                let hue = chroma(app, text.frame)
                XCTAssertGreaterThan(hue[0], hue[1] + 0.5, "Authored semantic ink remains red/orange: \(hue)")
                XCTAssertGreaterThan(hue[0], hue[2] + 0.5)
            }
            let title = app.navigationBars.staticTexts["Home audit report"].firstMatch
            let hue = chroma(app, title.frame)
            XCTAssertGreaterThan(hue[0], hue[1] + 0.5, "Only native HTML sheet chrome is themed")
            capture(app, "authored-html-\(mode)")
            app.buttons["Done"].tap()
            app.terminate()
        }
    }

    func testHTMLSheetRunsPageScriptsWithoutNetwork() throws {
        continueAfterFailure = false
        let probe = try HTMLProbeListeners()
        defer { probe.cancel() }

        let control = XCUIApplication()
        control.launchArguments = ["-tron-chat-display-fixture", "-display-document-html-control"] + probe.launchArguments
        control.launch()
        XCTAssertTrue(probe.waitForRequest("/navigate", timeout: 40), "Unrestricted control never navigated: \(probe.summary)")
        let reached = probe.requests
        for path in ["/stylesheet", "/css-image", "/image", "/fetch", "/xhr", "/beacon", "/socket", "/events",
                     "/script-image", "/script", "/frame", "/frame-fetch", "/worker", "/navigate"] {
            XCTAssertTrue(reached.contains(path), "The control page must reach \(path): \(probe.summary)")
        }
        XCTAssertGreaterThan(probe.idleConnections, 0, "The control page must preconnect: \(probe.summary)")
        XCTAssertGreaterThan(probe.datagrams, 0, "The control page must send WebRTC STUN: \(probe.summary)")
        control.terminate()
        probe.reset()

        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-display-document-theme", "-display-document-home",
                               "-display-document-html-probe", "-themeColor", "burgundy", "-polish-light"] + probe.launchArguments
        app.launch()
        defer { app.terminate() }
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home audit report")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), app.debugDescription)
        chip.tap()
        XCTAssertTrue(app.staticTexts["First content line"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Script ran"].firstMatch.waitForExistence(timeout: 10),
                      "The HTML sheet runs page scripts: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Module import 42"].firstMatch.waitForExistence(timeout: 10),
                      "A blob: module import runs: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["WebGL true"].firstMatch.waitForExistence(timeout: 10),
                      "A WebGL canvas is available: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Navigation attempted"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(probe.summary, "requests=[] idle=0 datagrams=0", "The sandboxed page reached the network")
        XCTAssertTrue(app.staticTexts["First content line"].firstMatch.exists, "Navigation away is cancelled")
        capture(app, "html-sheet-sandboxed-script")
        app.terminate()

        let floating = XCUIApplication()
        floating.launchArguments = app.launchArguments + ["-display-document-html-floating"]
        floating.launch()
        defer { floating.terminate() }
        let window = floating.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home audit report")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), floating.debugDescription)
        window.tap()
        XCTAssertTrue(floating.staticTexts["First content line"].firstMatch.waitForExistence(timeout: 10), floating.debugDescription)
        XCTAssertTrue(floating.staticTexts["Script idle"].firstMatch.exists,
                      "Only the sheet runs page scripts: \(floating.debugDescription)")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(probe.summary, "requests=[] idle=0 datagrams=0", "The floating page reached the network")
    }

    func testHTMLSheetFirstLineStartsBelowToolbar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-display-document-theme", "-display-document-home",
                               "-display-document-html-probe", "-themeColor", "burgundy", "-polish-light"]
        app.launch()
        defer { app.terminate() }
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home audit report")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), app.debugDescription)
        chip.tap()
        let first = app.staticTexts["First content line"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        let pinned = app.staticTexts["Pinned line"].firstMatch
        let done = app.buttons["Done"].firstMatch
        let page = app.webViews.firstMatch
        capture(app, "html-sheet-first-line")
        XCTAssertLessThanOrEqual(page.frame.minY, done.frame.minY,
                                 "The page extends under the toolbar blur: \(page.frame) vs Done \(done.frame)")
        XCTAssertGreaterThanOrEqual(first.frame.minY, done.frame.maxY,
                                    "The first line starts below the toolbar: \(first.frame) vs Done \(done.frame)")
        page.swipeUp()
        XCTAssertLessThan(first.frame.maxY, done.frame.minY, "The page scrolls under the toolbar: \(first.frame)")
        XCTAssertGreaterThanOrEqual(pinned.frame.minY, done.frame.maxY,
                                    "A sticky line stays below the toolbar: \(pinned.frame) vs Done \(done.frame)")
        capture(app, "html-sheet-scrolled")
        page.swipeDown()
        page.swipeDown()
        XCTAssertGreaterThanOrEqual(first.frame.minY, done.frame.maxY,
                                    "The first line rests below the toolbar after scrolling back: \(first.frame)")
    }

    private func open(theme: String, mode: String, home: Bool, html: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-tron-chat-display-fixture", "-display-document-theme", "-themeColor", theme]
            + (mode == "light" ? ["-polish-light"] : [])
            + (home ? ["-display-document-home"] : [])
            + (html ? ["-display-document-html"] : [])
        app.launch()
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", home ? "Home audit report" : "Session summary")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), app.debugDescription)
        chip.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", html ? "Authored document" : "Navigation evidence")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "2001-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func chroma(_ app: XCUIApplication, _ frame: CGRect) -> [Double] {
        let source = app.screenshot().image.cgImage!
        let scale = CGFloat(source.width) / app.windows.firstMatch.frame.width
        guard let crop = source.cropping(to: frame.applying(CGAffineTransform(scaleX: scale, y: scale))) else {
            XCTFail("No rendered area: \(frame)"); return [0, 0, 0]
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
            if rgb.max()! - rgb.min()! < 45 { continue }
            for c in 0..<3 { sum[c] += rgb[c] }
            count += 1
        }
        XCTAssertGreaterThan(count, 0, "No colored ink in \(frame)")
        let low = sum.min()!, range = sum.max()! - low
        return sum.map { ($0 - low) / max(range, 1) }
    }
}

private final class HTMLProbeListeners: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "html-probe-listeners")
    private let http: NWListener
    private let idle: NWListener
    private let stun: NWListener
    private var requestPaths: [String] = []
    private var idleCount = 0
    private var datagramCount = 0

    init() throws {
        http = try NWListener(using: .tcp)
        idle = try NWListener(using: .tcp)
        stun = try NWListener(using: .udp)
        http.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        idle.newConnectionHandler = { [weak self] connection in
            self?.record { $0.idleCount += 1 }
            connection.cancel()
        }
        stun.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receiveMessage { _, _, _, _ in
                self.record { $0.datagramCount += 1 }
                connection.cancel()
            }
        }
        let ready = DispatchSemaphore(value: 0)
        for listener in [http, idle, stun] {
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.start(queue: queue)
        }
        for _ in 0..<3 where ready.wait(timeout: .now() + 10) == .timedOut {
            throw POSIXError(.ETIMEDOUT)
        }
    }

    var launchArguments: [String] {
        ["-display-html-probe-http", "\(http.port!.rawValue)", "-display-html-probe-idle", "\(idle.port!.rawValue)",
         "-display-html-probe-stun", "\(stun.port!.rawValue)"]
    }

    var requests: Set<String> { lock.withLock { Set(requestPaths) } }
    var idleConnections: Int { lock.withLock { idleCount } }
    var datagrams: Int { lock.withLock { datagramCount } }
    var summary: String {
        lock.withLock { "requests=\(requestPaths.sorted()) idle=\(idleCount) datagrams=\(datagramCount)" }
    }

    func reset() {
        record {
            $0.requestPaths = []
            $0.idleCount = 0
            $0.datagramCount = 0
        }
    }

    func waitForRequest(_ path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if requests.contains(path) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func cancel() {
        for listener in [http, idle, stun] { listener.cancel() }
    }

    private func record(_ change: (HTMLProbeListeners) -> Void) {
        lock.withLock { change(self) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            self?.record { $0.requestPaths.append(parts.count > 1 ? String(parts[1]) : "<connection without request>") }
            let reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
