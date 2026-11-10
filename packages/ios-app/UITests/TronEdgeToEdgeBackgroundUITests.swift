import XCTest

@MainActor
final class TronEdgeToEdgeBackgroundUITests: XCTestCase {
    func testDashboardBackgroundReachesEveryWindowEdge() {
        for (orientation, dark) in combos() {
            let app = launch(["-dashboard-view-home"] + (dark ? ["-home-dark"] : []), orientation)
            XCTAssertTrue(app.staticTexts["dashboard.title"].waitForExistence(timeout: 15), app.debugDescription)
            Thread.sleep(forTimeInterval: 1.5)
            assertEdgeToEdge(app, "dashboard-\(orientation.rawValue)-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    func testChatBackgroundReachesEveryWindowEdge() {
        for (orientation, dark) in combos() {
            let app = launch(dark ? ["-home-dark"] : [], orientation)
            let row = app.buttons["home-pinned-row"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
            row.tap()
            XCTAssertTrue(app.textViews["Message input"].waitForExistence(timeout: 10), app.debugDescription)
            Thread.sleep(forTimeInterval: 1.5)
            assertEdgeToEdge(app, "chat-\(orientation.rawValue)-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    private func combos() -> [(UIDeviceOrientation, Bool)] {
        let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad ? [.landscapeLeft, .portrait] : [.portrait]
        return orientations.flatMap { [($0, false), ($0, true)] }
    }

    private func launch(_ extra: [String], _ orientation: UIDeviceOrientation) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-tron-home-dashboard-fixture", "-home-shell-ready"] + extra
        app.launch()
        return app
    }

    private func assertEdgeToEdge(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "edge-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let cg = shot.image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("No pixels")
        }
        let w = cg.width, h = cg.height, bpp = cg.bitsPerPixel / 8, rowBytes = cg.bytesPerRow
        func mean(_ points: [(Int, Int)]) -> Double {
            var sum = 0
            for (x, y) in points { let p = bytes + y * rowBytes + x * bpp; sum += Int(p[0]) + Int(p[1]) + Int(p[2]) }
            return Double(sum) / Double(points.count * 3)
        }
        let band = 120 ... 220
        func horizontal(_ y: Int) -> [(Int, Int)] { (band.lowerBound ..< (w - band.lowerBound)).filter { $0 % 3 == 0 }.map { ($0, y) } }
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").frame
        let scale = Double(max(w, h)) / Double(max(screen.width, screen.height))
        let indicator = (w / 2 - Int(80 * scale)) ..< (w / 2 + Int(80 * scale))
        func bottom(_ y: Int) -> [(Int, Int)] { horizontal(y).filter { !indicator.contains($0.0) } }
        func vertical(_ x: Int) -> [(Int, Int)] { (band.lowerBound ..< (h - band.lowerBound)).filter { $0 % 3 == 0 }.map { (x, $0) } }
        func steps(_ line: (Int) -> [(Int, Int)]) -> Double {
            var worst = 0.0
            for depth in stride(from: 4, through: 48, by: 2) {
                let outer = line(depth), inner = line(depth + 2)
                var diffs: [Double] = []
                for (a, b) in zip(outer, inner) {
                    let p = bytes + a.1 * rowBytes + a.0 * bpp, q = bytes + b.1 * rowBytes + b.0 * bpp
                    diffs.append(Double(abs(Int(p[0]) - Int(q[0])) + abs(Int(p[1]) - Int(q[1])) + abs(Int(p[2]) - Int(q[2]))) / 3)
                }
                worst = max(worst, diffs.sorted()[diffs.count / 2])
            }
            return worst
        }
        let edges: [(String, Double)] = [
            ("top", steps { horizontal($0) }),
            ("bottom", steps { bottom(h - 1 - $0) }),
            ("leading", steps { vertical($0) }),
            ("trailing", steps { vertical(w - 1 - $0) }),
        ]
        for (edge, step) in edges {
            XCTAssertLessThan(step, 9, "\(name): a background step \(step) within 24 pt of the \(edge) window edge: a clipped safe-area strip")
        }
    }
}
