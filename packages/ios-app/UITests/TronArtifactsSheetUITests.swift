import Network
import XCTest

@MainActor final class TronArtifactsSheetUITests: XCTestCase {
    func testToolsAndDailyReportsListAsCompactRowsInLightAndDark() {
        continueAfterFailure = false
        for mode in ["light", "dark"] {
            let app = launch(mode == "dark" ? ["-artifacts-dark"] : [])
            defer { app.terminate() }
            let tool = app.buttons["artifact-row-ios-dev-builds"]
            XCTAssertTrue(tool.waitForExistence(timeout: 10), app.debugDescription)
            let headers = ["header-tools", "header-day-"].map {
                app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "artifacts-\($0)")).firstMatch
            }
            XCTAssertTrue(headers.allSatisfy(\.exists), app.debugDescription)
            XCTAssertTrue(headers[0].label.hasPrefix("Tools"), headers[0].label)
            let todays = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'artifacts-header-day-'"))
            XCTAssertEqual(todays.element(boundBy: 0).label.components(separatedBy: ",").first, "Today", todays.element(boundBy: 0).label)
            XCTAssertEqual(todays.element(boundBy: 1).label.components(separatedBy: ",").first, "Yesterday", todays.element(boundBy: 1).label)
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'artifact-row-'"))
            let order = (0..<rows.count).map { rows.element(boundBy: $0) }.sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
            XCTAssertEqual(order.map { $0.components(separatedBy: ",").first ?? "" },
                           ["Tron iOS development builds", "Provider usage dashboard", "Weekly status",
                            "Artifacts sheet audit with a deliberately long title that must stay on one line", "Release guide", "Gap year schedule"])
            XCTAssertTrue(tool.label.hasSuffix("2h ago"), tool.label)
            for name in ["ios-dev-builds", rowName(app, "sheet-audit")] {
                let marker = { (id: String) in app.descendants(matching: .any)[id] }
                let title = marker("artifact-row-\(name)-title"), time = marker("artifact-row-\(name)-metadata")
                XCTAssertTrue(title.exists && time.exists, app.debugDescription)
                XCTAssertEqual(title.frame.midY, time.frame.midY, accuracy: 4, "Title and time share one line")
                XCTAssertLessThanOrEqual(marker("artifact-card-\(name)-container").frame.height, 50, "Compact single-line row")
            }
            keep(app, "artifacts-list-\(mode)")
        }
    }

    func testEmptyStateUsesTheSharedPlaceholder() {
        let app = launch([], scenario: "artifacts-empty")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "No artifacts yet")).firstMatch
            .waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'artifact-row-'")).firstMatch.exists)
        keep(app, "artifacts-empty-light")
    }

    func testOpenedArtifactLoadsInAppAndClosingReturnsToTheList() throws {
        continueAfterFailure = false
        let server = try PageServer()
        defer { server.cancel() }
        let app = launch(["-artifacts-base-url", "http://127.0.0.1:\(server.port)"])
        defer { app.terminate() }
        let tool = app.buttons["artifact-row-ios-dev-builds"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10), app.debugDescription)
        for pass in 1...2 {
            let served = server.userAgents.count
            tool.tap()
            let deadline = Date().addingTimeInterval(15)
            while server.userAgents.count == served && Date() < deadline { RunLoop.current.run(until: .now + 0.2) }
            let agent = try XCTUnwrap(server.userAgents.last, "The opened artifact never requested its page")
            XCTAssertFalse(agent.contains("Safari/"), "The page loads in the app's own WebKit view, not Safari, which iCloud Private Relay covers: \(agent)")
            XCTAssertTrue(app.webViews.staticTexts["Served page for /artifacts/ios-dev-builds/"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(app.buttons["Open in Safari"].exists, app.debugDescription)
            keep(app, "artifacts-opened-\(pass)")
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(tool.waitForExistence(timeout: 5), "Closing the opened page returns to the Artifacts list: \(app.debugDescription)")
            keep(app, "artifacts-after-close-\(pass)")
        }
    }

    private func launch(_ extra: [String], scenario: String = "artifacts") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-tron-integrations-fixture", "-integrations-scenario", scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        let open = app.buttons["Artifacts"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), app.debugDescription)
        open.tap()
        return app
    }

    private func rowName(_ app: XCUIApplication, _ slug: String) -> String {
        let row = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "_\(slug)")).firstMatch
        return String(row.identifier.dropFirst("artifact-row-".count))
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class PageServer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "artifacts-page-server")
    private let listener: NWListener
    private var agents: [String] = []

    init() throws {
        let tcp = NWParameters.tcp
        tcp.requiredInterfaceType = .loopback
        listener = try NWListener(using: tcp)
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 10) == .timedOut { throw POSIXError(.ETIMEDOUT) }
    }

    var port: UInt16 { listener.port!.rawValue }
    var userAgents: [String] { lock.withLock { agents } }
    func cancel() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let lines = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n") ?? []
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let agent = lines.first { $0.lowercased().hasPrefix("user-agent:") }.map { String($0.dropFirst(11)).trimmingCharacters(in: .whitespaces) }
            if let agent, path != "/favicon.ico" { self?.lock.withLock { self?.agents.append(agent) } }
            let body = "<!doctype html><meta name=viewport content='width=device-width'><title>Page</title><h1>Served page for \(path)</h1>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
