import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class WorkerToolRegressionViewTests: ShuffledTestCase {
    func testReportShowsMarkdownSummaryEvidenceAndReadableOutcome() async throws {
        for (raw, readable) in [("final", "Done"), ("progress", "Progress"), ("needs-input", "Needs input")] {
            try await surface("worker-report", extra: ["-worker-report-outcome", raw]) { app in
                try await app.until("the report header") { app.staticText("Report result") != nil }
                try await app.until("the outcome") { app.element("home-tool-outcome") != nil }
                XCTAssertEqual(app.element("home-tool-outcome")?.accessibilityLabel, "Report result, " + readable)
                XCTAssertNotNil(app.element("home-tool-text-report"), "Report body must use the custom shared Markdown section")
                XCTAssertNotNil(app.element("home-tool-text-evidence"), "Acceptance evidence must not disappear behind the receipt")
                XCTAssertNotNil(app.staticText("Tool sheets ready"), "Markdown heading must render without ##")
                XCTAssertNil(app.staticText("Task report sealed."), "Receipt text is not the report body")
                XCTAssertFalse(MountedFixture.elements(in: app.top).contains {
                    !$0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("5dee638b") == true
                })
                XCTAssertNotNil(app.button("Technical details"), "Raw request/result remain reachable")
            }
        }
    }

    func testCheckinKeepsCustomAttentionProgressAndFriendlyTitle() async throws {
        try await surface("worker-checkin", dark: true) { app in
            try await app.until("the check-in header") { app.staticText("Check in") != nil }
            try await app.until("the outcome") { app.element("home-tool-outcome") != nil }
            XCTAssertEqual(app.element("home-tool-outcome")?.accessibilityLabel,
                           "Landed with explicit validation deferral, Needs attention")
            for (title, value) in [("Attention", "Requested"), ("Blocker", "Visual approval is needed before testing and landing."),
                                   ("Next", "Review the previews, then run focused UI regressions after approval.")] {
                try await app.until("the \(title) row") { app.element("home-tool-row-\(title)") != nil }
                XCTAssertTrue(app.element("home-tool-row-\(title)")?.accessibilityLabel?.contains(value) == true,
                              "Preserve the canonical \(title) value")
            }
            XCTAssertFalse(MountedFixture.elements(in: app.top).contains {
                !$0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("Checkin Object") == true
            })
        }
    }

    func testTranscriptChipsUseFriendlyNames() async throws {
        try await surface("worker-chips") { app in
            for title in ["Report result", "Check in", "14 tools"] {
                try await app.until("the \(title) chip") { app.labelled(title) != nil }
            }
            XCTAssertNil(app.labelled("report,"))
            XCTAssertNil(app.labelled("checkin,"))
        }
    }

    private func surface(_ name: String, dark: Bool = false, extra: [String] = [],
                         _ body: (MountedFixture) async throws -> Void) async throws {
        try await mounted(["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", name,
                           "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                          + (dark ? ["-settings-dark"] : []) + extra, theme: .burgundy) { app in
            try await app.until("the surface") { app.button("Done") != nil }
            try await body(app)
        }
    }
}
