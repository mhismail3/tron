import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SixSmallUIRegressionViewTests: ShuffledTestCase {
    func testHomeSettingsOrder() async throws {
        for mode in ["light", "dark"] {
            try await surface("home", mode: mode) { app in
                let titles = ["Workers & delegation", "Tools", "Connection"]
                try await app.until("the Home Settings headings") { titles.allSatisfy { heading(app, $0) != nil } }
                let frames = titles.map { heading(app, $0)!.accessibilityFrame }
                XCTAssertLessThan(frames[0].minY, frames[1].minY)
                XCTAssertLessThan(frames[1].minY, frames[2].minY)
                for id in ["settings-section-model-open", "settings-section-tools-open", "settings-section-advanced-open"] {
                    XCTAssertFalse(MountedFixture.elements(in: app.top).contains {
                        MountedFixture.identifier($0) == id && $0.accessibilityTraits.contains(.button)
                    }, id)
                }
            }
        }
    }

    func testSessionSettingsOrder() async throws {
        for mode in ["light", "dark"] {
            try await surface("session", mode: mode) { app in
                let titles = ["Compaction", "Tools", "Project Trust", "More Settings"]
                try await app.until("the Session Settings rows") { titles.allSatisfy { button(app, $0) != nil } }
                let mids = titles.map { button(app, $0)!.accessibilityFrame.midY }
                for index in 1..<mids.count {
                    XCTAssertLessThan(mids[index - 1], mids[index], "\(titles[index - 1]) must precede \(titles[index])")
                }
            }
        }
    }

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

    private func surface(_ name: String, mode: String = "light", extra: [String] = [],
                         _ body: (MountedFixture) async throws -> Void) async throws {
        try await mounted(["-tron-settings-renderer-fixture", "-settings-expanded-review", "-six-ui-surface", name] + extra
                          + (mode == "dark" ? ["-settings-renderer-dark"] : []), theme: .burgundy) { app in
            try await app.until("the surface") { app.element("Done") != nil }
            try await body(app)
        }
    }

    private func heading(_ app: MountedFixture, _ title: String) -> NSObject? {
        MountedFixture.elements(in: app.top).last {
            $0.isAccessibilityElement && $0.accessibilityLabel == title && !$0.accessibilityTraits.contains(.button)
        }
    }

    private func button(_ app: MountedFixture, _ title: String) -> NSObject? {
        MountedFixture.elements(in: app.top).last {
            $0.isAccessibilityElement && $0.accessibilityLabel == title && $0.accessibilityTraits.contains(.button)
        }
    }
}
