import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeControlsViewTests: ShuffledTestCase {
    func testDisableHomeSubtitleMatchesDestructiveTitle() async throws {
        for mode in ["light", "dark"] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"] + (mode == "dark" ? ["-home-dark"] : [])) { app in
                try await openManageHome(app)
                XCTAssertNil(app.element("home-manage-pause"), "Pause is not a Manage Home row")
                XCTAssertNil(app.element("home-manage-disable"), "Disable is not a Manage Home row")
                _ = try await revealed(app, "home-manage-settings")
                try await app.activate("home-manage-settings")
                try await app.until("Home Settings opens") { app.element("home-settings-controls") != nil }
                try await app.expandTopSheet()
                for _ in 0..<8 {
                    let node = try await revealed(app, "home-manage-disable")
                    if app.window.bounds.insetBy(dx: 0, dy: 50).contains(node.accessibilityFrame) { break }
                }
                XCTAssertTrue(app.window.bounds.contains(try XCTUnwrap(app.element("home-manage-disable")).accessibilityFrame),
                              "Disable Home is on screen\n\(app.tree())")
                @MainActor func redCount() -> [Double]? {
                    guard let row = app.element("home-manage-disable") else { return nil }
                    var area = row.accessibilityFrame; area.size.width = 50
                    guard let pixels = app.pixels(area) else { return nil }
                    return [Double(pixels.filter { $0[0] > $0[1] * 1.4 && $0[0] > $0[2] * 1.4 && $0[0] > 60 }.count)]
                }
                let red = try await app.still("Disable Home's icon") { redCount() }
                XCTAssertGreaterThan(red[0], 20, "The decorative icon paints destructive red, not inherited green")
                @MainActor func half(_ top: Bool) -> CGRect? {
                    app.element("home-manage-disable").map { node in
                        let frame = node.accessibilityFrame
                        return CGRect(x: frame.minX + 56, y: top ? frame.minY : frame.midY,
                                      width: frame.width - 56, height: frame.height / 2)
                    }
                }
                let title = try await app.inked("Disable Home's title") { half(true) }
                let subtitle = try await app.inked("Disable Home's subtitle") { half(false) }
                XCTAssertGreaterThan(title[0] - max(title[1], title[2]), 0.3, "Destructive title is red in \(mode)")
                XCTAssertLessThan(zip(title, subtitle).map { abs($0 - $1) }.max()!, 0.12,
                                  "Disable Home's subtitle matches its destructive title in \(mode): \(subtitle) vs \(title)")
            }
        }
    }
}
