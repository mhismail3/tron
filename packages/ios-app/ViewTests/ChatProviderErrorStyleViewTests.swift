import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ChatProviderErrorStyleViewTests: ShuffledTestCase {
    func testErrorPillsStayCenteredInLightAndDark() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-chat-haptics-fixture", "-chat-provider-errors", "-error-style-preview"]
                              + (dark ? ["-error-preview-dark"] : [])) { app in
                try await assertCenteredInk(app, "the single error") {
                    MountedFixture.elements(in: app.top).last { (MountedFixture.identifier($0) ?? "").hasPrefix("chat-error-run-") }
                }
                try await app.activate("Live error")
                try await assertCenteredInk(app, "the grouped error") {
                    MountedFixture.elements(in: app.top).last { node in
                        let label = node.accessibilityLabel ?? ""
                        return node.isAccessibilityElement && label.contains("Anthropic is overloaded") && label.contains("2 errors")
                    }
                }
                try await app.activate("Settle error")
                try await app.activate("Mixed error")
                try await assertCenteredInk(app, "the mixed error") {
                    MountedFixture.elements(in: app.top).last {
                        $0.isAccessibilityElement && $0.accessibilityLabel?.contains("Provider errors") == true
                    }
                }
            }
        }
    }

    private func assertCenteredInk(_ app: MountedFixture, _ what: String, _ pill: () -> NSObject?) async throws {
        try await app.until("\(what) exists") { pill() != nil }
        let center = try await app.still("\(what) ink") { pill().flatMap { inkCenter(app, $0.accessibilityFrame) }.map { [$0] } }
        XCTAssertEqual(center[0], app.window.bounds.midX, accuracy: 4,
                       "Visible error pill must be horizontally centered, including grouped runs")
    }

    private func inkCenter(_ app: MountedFixture, _ frame: CGRect) -> Double? {
        let bounds = frame.intersection(app.window.bounds).integral
        guard !bounds.isEmpty, let pixels = app.pixels(bounds) else { return nil }
        let width = Int(bounds.width * app.window.screen.scale)
        var left = width, right = -1
        for (index, rgb) in pixels.enumerated() {
            let r = rgb[0], g = rgb[1], b = rgb[2]
            if r > 120 && r > g + 35 && r > b + 35 { left = min(left, index % width); right = max(right, index % width) }
        }
        guard right >= left else { return nil }
        return Double(bounds.minX) + Double(left + right + 1) / 2 / Double(app.window.screen.scale)
    }
}
