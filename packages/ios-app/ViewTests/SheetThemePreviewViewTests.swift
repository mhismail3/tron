import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SheetThemePreviewViewTests: ShuffledTestCase {
    func testMaintenanceContainersFollowSheetThemeAndForgetStaysDestructive() async throws {
        for mode in ["light", "dark"] {
            try await settings(mode) { app in
                try await open(app, "Details for Fixture", title: "Fixture")
                for label in ["Rebuild from Source", "Restart", "Disable"] {
                    try await app.until("\(label) exists") { app.element(label) != nil }
                }
                _ = try await app.still("Fixture's title") {
                    app.navigationTitle("Fixture").map { color(app, $0.accessibilityFrame, ink: true) }
                }
                let image = app.render()
                for label in ["Rebuild from Source", "Restart", "Disable"] {
                    assertColor(app, area: containerPatch(app.element(label)!.accessibilityFrame), title: "Fixture", image: image)
                }
                let red = color(app, containerPatch(app.element("Forget Server")!.accessibilityFrame), ink: false, image: image)
                XCTAssertGreaterThan(red[0], red[1] + 0.05, "Forget Server must remain red: \(red)")
                XCTAssertGreaterThan(red[0], red[2] + 0.05, "Forget Server must remain red: \(red)")
            }
        }
    }

    private func settings(_ mode: String, _ body: (MountedFixture) async throws -> Void) async throws {
        try await mounted(["-tron-settings-renderer-fixture", "-settings-nested", "-settings-expanded-review", "-settings-sheet-theme-review"]
                          + (mode == "dark" ? ["-settings-renderer-dark"] : [])) { app in
            try await app.activate("Open Settings")
            try await app.until("Global Settings opens") { app.navigationTitle("Global Settings") != nil }
            try await app.expandTopSheet()
            try await open(app, "settings-link-Connections", title: "Connections")
            try await body(app)
        }
    }

    private func open(_ app: MountedFixture, _ key: String, title: String) async throws {
        _ = try await revealed(app, key)
        try await app.activate(key)
        try await app.until("\(title) opens") { app.navigationTitle(title) != nil }
        try await app.expandTopSheet()
    }

    private func containerPatch(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.midX - 2, y: frame.minY + 4, width: 5, height: 3)
    }

    private func assertColor(_ app: MountedFixture, area: CGRect, title: String, image: UIImage,
                             file: StaticString = #filePath, line: UInt = #line) {
        let expected = chroma(color(app, app.navigationTitle(title)!.accessibilityFrame, ink: true, image: image))
        let actual = chroma(color(app, area, ink: false, image: image))
        XCTAssertLessThan(zip(expected, actual).map { abs($0 - $1) }.max() ?? 1, 0.28,
                          "Rendered container chroma \(actual) differs from sheet title \(expected)", file: file, line: line)
    }

    private func chroma(_ rgb: [Double]) -> [Double] {
        let low = rgb.min()!, range = rgb.max()! - low
        return rgb.map { ($0 - low) / max(range, 0.001) }
    }

    private func color(_ app: MountedFixture, _ area: CGRect, ink: Bool, image: UIImage? = nil) -> [Double] {
        let pixels = app.pixels(area, image: image) ?? []
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for rgb in pixels {
            if ink && rgb.max()! - rgb.min()! < 60 { continue }
            for c in 0..<3 { sum[c] += rgb[c] / 255 }
            count += 1
        }
        XCTAssertGreaterThan(count, 0, "No rendered color in \(area)")
        return sum.map { $0 / max(count, 1) }
    }
}
