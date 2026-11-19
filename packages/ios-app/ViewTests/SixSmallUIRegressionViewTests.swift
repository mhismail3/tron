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

    func testCheckinShowsSummaryProgressAttentionAndTimestamp() async throws {
        for blocked in [false, true] {
            try await surface(blocked ? "checkin-blocked" : "checkin") { app in
                try await app.until("the check-in summary") {
                    MountedFixture.elements(in: app.top).contains {
                        let label = $0.accessibilityLabel ?? ""
                        return !$0.accessibilityTraits.contains(.button) && (label == "Landed with explicit validation deferral"
                            || label.hasPrefix("Landed with explicit validation deferral, "))
                    }
                }
                for text in ["Attention", "Needs attention", "Done", "Next", "Timestamp"] + (blocked ? ["Blocker"] : []) {
                    _ = try await revealed(app, "home-tool-row-\(text)")
                }
                XCTAssertFalse(MountedFixture.elements(in: app.top).contains {
                    !$0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("Checkin Object") == true
                }, app.tree())
            }
        }
    }

    func testCheckinValuesMatchCanonicalReceipt() async throws {
        for blocked in [false, true] {
            try await surface(blocked ? "checkin-blocked" : "checkin") { app in
                let expected = [
                    ("Attention", blocked ? "Requested" : "None"),
                    ("Needs attention", blocked ? "Yes" : "No"),
                    ("Done", "Prepared the six UI changes and captured light and dark simulator previews."),
                    ("Next", "Review the previews, then run focused UI regressions after approval."),
                    ("Timestamp", "2026")
                ] + (blocked ? [("Blocker", "Visual approval is needed before testing and landing.")] : [])
                for (title, value) in expected {
                    let row = try await revealed(app, "home-tool-row-\(title)")
                    let label = (app.element("home-tool-row-\(title)") ?? row).accessibilityLabel ?? ""
                    XCTAssertTrue(label.contains(value), "\(title) must preserve receipt value: \(label)")
                }
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
