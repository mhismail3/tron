import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class EdgeToEdgeBackgroundViewTests: ShuffledTestCase {
    func testDashboardBackgroundReachesEveryWindowEdge() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-dashboard-view-home"] + (dark ? ["-home-dark"] : [])) { app in
                try await app.until("the dashboard title") { app.element("dashboard.title") != nil }
                try await assertEdgeToEdge(app, "dashboard-portrait-\(dark ? "dark" : "light")")
            }
        }
    }

    func testChatBackgroundReachesEveryWindowEdge() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"] + (dark ? ["-home-dark"] : [])) { app in
                try await app.activate("home-pinned-row")
                try await app.until("the composer") { app.element("Message input") != nil }
                try await assertEdgeToEdge(app, "chat-portrait-\(dark ? "dark" : "light")")
            }
        }
    }

    private func assertEdgeToEdge(_ app: MountedFixture, _ name: String) async throws {
        let corners = [CGRect(x: 0, y: 0, width: 8, height: 8), CGRect(x: app.window.bounds.maxX - 8, y: app.window.bounds.maxY - 8, width: 8, height: 8)]
        _ = try await app.still("\(name) background") { corners.compactMap { app.pixels($0) }.flatMap { $0.flatMap { $0 } }.map { $0 / 255 } }
        let image = app.render()
        guard let pixels = app.pixels(app.window.bounds, image: image), let cg = image.cgImage else { return XCTFail("No pixels") }
        let w = cg.width, h = cg.height
        func value(_ x: Int, _ y: Int) -> [Double] { pixels[y * w + x] }
        let band = 120 ... 220
        func horizontal(_ y: Int) -> [(Int, Int)] { (band.lowerBound ..< (w - band.lowerBound)).filter { $0 % 3 == 0 }.map { ($0, y) } }
        let scale = Double(cg.width) / Double(app.window.bounds.width)
        let indicator = (w / 2 - Int(80 * scale)) ..< (w / 2 + Int(80 * scale))
        func bottom(_ y: Int) -> [(Int, Int)] { horizontal(y).filter { !indicator.contains($0.0) } }
        func vertical(_ x: Int) -> [(Int, Int)] { (band.lowerBound ..< (h - band.lowerBound)).filter { $0 % 3 == 0 }.map { (x, $0) } }
        func steps(_ line: (Int) -> [(Int, Int)]) -> Double {
            var worst = 0.0
            for depth in stride(from: 4, through: 48, by: 2) {
                let diffs = zip(line(depth), line(depth + 2)).map { a, b in
                    zip(value(a.0, a.1), value(b.0, b.1)).map { abs($0 - $1) }.reduce(0, +) / 3
                }.sorted()
                worst = max(worst, diffs[diffs.count / 2])
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
            print("EDGE \(name) \(edge) \(step)")
            XCTAssertLessThan(step, 9, "\(name): a background step \(step) within 24 pt of the \(edge) window edge: a clipped safe-area strip")
        }
    }
}
