import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class BurgundyGlassViewTests: ShuffledTestCase {
    func testWineGlassKeepsInkReadableAndLightBurgundyUnchanged() async throws {
        for mode in ["light", "dark"] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-active",
                               "-home-sheet-dashboard-workers", "-dashboard-view-home", "-settings-scope-review"]
                              + (mode == "dark" ? ["-home-dark"] : []), theme: .burgundy) { app in
                try await app.until("the Home usage card") { app.element("home-usage-card") != nil }
                let frame = app.element("home-usage-card")!.accessibilityFrame
                try await check(app, ink: CGRect(x: frame.minX + frame.width * 0.48, y: frame.minY + frame.height * 0.08,
                                                 width: frame.width * 0.49, height: frame.height * 0.24),
                                background: CGRect(x: frame.minX + frame.width * 0.40, y: frame.minY + frame.height * 0.18,
                                                   width: 4, height: 4), mode: mode, name: "Home usage", darkContrastFloor: 2.564)
                try await app.until("the Home button") { app.element("dashboard.menu") is UIButton }
                (app.element("dashboard.menu") as! UIButton).sendActions(for: .primaryActionTriggered)
                try await app.activate("session-context-button")
                try await app.until("Manage Home opens") { app.element("home-manage-state") != nil }
                try await app.expandTopSheet()
                _ = try await revealed(app, "home-manage-settings")
                try await app.activate("home-manage-settings")
                try await app.until("Home Settings opens") { app.element("settings-row-model.queue_role_worker_") != nil }
                try await app.expandTopSheet()
                let row = try await revealed(app, "settings-row-model.queue_role_worker_").accessibilityFrame
                try await check(app, ink: CGRect(x: row.minX, y: row.midY - 12, width: 30, height: 24),
                                background: CGRect(x: row.midX - 2, y: row.minY + 4, width: 4, height: 4),
                                mode: mode, name: "Inherited Home Settings", darkContrastFloor: 2.505)
            }
        }
    }

    private func check(_ app: MountedFixture, ink: CGRect, background: CGRect, mode: String, name: String,
                       darkContrastFloor: Double) async throws {
        _ = try await app.still("\(name) ink") {
            app.pixels(ink).map(saturated).flatMap { $0.isEmpty ? nil : foreground($0) }
        }
        let image = app.render()
        let saturated = saturated(app.pixels(ink, image: image) ?? [])
        XCTAssertGreaterThanOrEqual(saturated.count, 32, "Missing rendered primary ink: \(name)")
        let foreground = foreground(saturated)
        let patch = app.pixels(background, image: image) ?? []
        let backdrop = (0..<3).map { c in patch.map { $0[c] }.sorted()[patch.count / 2] }
        let a = luminance(foreground), b = luminance(backdrop)
        let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        print("WINE_GLASS \(name)-\(mode) ink=\(foreground) background=\(backdrop) contrast=\(contrast)")
        XCTAssertGreaterThanOrEqual(contrast, mode == "dark" ? darkContrastFloor : 4.5,
                                    "\(name) primary ink must retain contrast on actual glass")
        if mode == "dark" {
            let inkHue = (foreground[2] - foreground[1]) / max(foreground[0] - foreground[1], 1)
            XCTAssertGreaterThanOrEqual(inkHue, 0.35, "Primary ink must lean purple-burgundy, not crimson")
            XCTAssertLessThanOrEqual(inkHue, 0.63, "Primary ink must remain burgundy, not turn violet")
            XCTAssertGreaterThanOrEqual((foreground[0] - foreground[1]) / foreground[0], 0.60,
                                        "Primary ink must stay saturated, not pastel")
            XCTAssertGreaterThanOrEqual(a, 0.16, "Primary ink must not darken beyond the approved appearance")
            XCTAssertLessThanOrEqual(a, 0.165, "Primary ink must not brighten beyond the approved appearance")
            let wineHue = (backdrop[2] - backdrop[1]) / max(backdrop[0] - backdrop[1], 1)
            XCTAssertGreaterThanOrEqual(wineHue, 0.30, "Dark glass must use the wine surface role, not lifted salmon ink")
            XCTAssertLessThan(wineHue, 0.80, "Wine glass must stay red-dominant, not turn violet")
        } else {
            let unchanged = [87.0, 21.0, 47.0]
            XCTAssertLessThan(zip(foreground, unchanged).map { abs($0 - $1) }.max()!, 8,
                              "Light Burgundy must not change while refining dark mode")
        }
    }

    private func saturated(_ pixels: [[Double]]) -> [[Double]] {
        pixels.filter { $0.max()! - $0.min()! >= 28 }.sorted { ($0.max()! - $0.min()!) > ($1.max()! - $1.min()!) }
    }

    private func foreground(_ saturated: [[Double]]) -> [Double] {
        let selected = Array(saturated.prefix(32))
        return (0..<3).map { c in selected.map { $0[c] }.reduce(0, +) / Double(max(selected.count, 1)) }
    }

    private func luminance(_ rgb: [Double]) -> Double {
        zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
            let value = pair.0 / 255
            return sum + (value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)) * pair.1
        }
    }
}
