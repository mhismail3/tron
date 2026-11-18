import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SixSmallUIRegressionViewTests: ShuffledTestCase {
    func testModelRowUsesSharedSubtextAndMonospacedID() async throws {
        try await surface("models", extra: ["-six-ui-typography"]) { app in
            for slot in ["subtext", "metadata"] {
                let actualID = "model-picker-row-opencode-go/deepseek-v4-pro-\(slot)", referenceID = "six-ui-row-reference-\(slot)"
                try await app.until("the \(slot) markers") { app.element(actualID) != nil && app.element(referenceID) != nil }
                let actual = app.element(actualID)!.accessibilityFrame, reference = app.element(referenceID)!.accessibilityFrame
                XCTAssertEqual(actual.height, reference.height, accuracy: 0.5, "Catalog \(slot) must use the shared row's type metrics")
                XCTAssertEqual(actual.width, reference.width, accuracy: 0.5, "ID glyph advances must match the shared monospaced reference")
            }
        }
    }

    private func surface(_ name: String, extra: [String] = [], _ body: (MountedFixture) async throws -> Void) async throws {
        try await mounted(["-tron-settings-renderer-fixture", "-settings-expanded-review", "-six-ui-surface", name] + extra,
                          theme: .burgundy) { app in
            try await app.until("the surface") { app.element("Done") != nil }
            try await body(app)
        }
    }
}
