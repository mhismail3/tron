import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class TaskToolSheetViewTests: ShuffledTestCase {
    func testStatusShowsRecordedWorkerCheckinAndSpend() async throws {
        try await mounted(["-tron-tool-sheets-polish-fixture", "-polish-scenario", "task-status",
                           "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
            try await app.until("the task status sheet") { app.element("Technical details") != nil }
            XCTAssertTrue(MountedFixture.elements(in: app.top).contains {
                let label = $0.accessibilityLabel ?? ""
                return !$0.accessibilityTraits.contains(.button) && (label == "Keep Send disabled while photos prepare"
                    || label.hasPrefix("Keep Send disabled while photos prepare, "))
            }, app.tree())
            for (row, value) in [("Model", "Sol"), ("Check-in", "Attachment readiness now has one owner."), ("Tokens", "18K in")] {
                let node = try await revealed(app, "home-tool-row-\(row)")
                let label = (app.element("home-tool-row-\(row)") ?? node).accessibilityLabel ?? ""
                XCTAssertTrue(label.contains(value), "\(row) row: \(label)")
            }
        }
    }

    func testReportAndControlMessagesOpenOriginalTextInSharedReader() async throws {
        for scenario in ["task-report", "task-steer", "task-resume", "task-interrupt"] {
            try await mounted(["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                               "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
                try await app.until("the outcome") { app.element("home-tool-outcome") != nil }
                if scenario == "task-report" {
                    _ = try await revealed(app, "home-tool-row-Page")
                    XCTAssertTrue(label(app, "home-tool-row-Page").contains("Bytes 0–"), app.tree())
                } else {
                    XCTAssertTrue(label(app, "home-tool-outcome").contains("Accepted"), app.tree())
                }
                if scenario == "task-resume" {
                    _ = try await revealed(app, "home-tool-row-Continues as task")
                    XCTAssertTrue(label(app, "home-tool-row-Continues as task").contains("photo-readiness-2"))
                }
                let id = scenario == "task-report" ? "report" : "message"
                _ = try await revealed(app, "home-tool-text-\(id)-view-all")
                try await app.activate("home-tool-text-\(id)-view-all")
                try await app.until("the shared reader") { app.element("home-reading-text") != nil }
                let tail = "Wait for visual approval before behavioral regression runs or merging."
                try await app.until("the full reader tail") { tailNode(app, tail) != nil }
                try await app.reveal(tailNode(app, tail)!)
                XCTAssertTrue(app.onScreen(tailNode(app, tail)!), "Full reader retains the original tail")
            }
        }
    }

    func testMessageBodyUsesStandardTextInk() async throws {
        for mode in ["light", "dark"] {
            try await mounted(["-tron-tool-sheets-polish-fixture", "-polish-scenario", "task-steer", "-polish-\(mode)",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
                try await app.until("the message body") { app.element("home-tool-text-message") != nil }
                let body = app.element("home-tool-text-message")!.accessibilityFrame
                let area = body.insetBy(dx: 16, dy: 16).intersection(app.window.bounds)
                let text = CGRect(x: area.minX, y: area.minY, width: area.width, height: min(area.height, 160))
                let pixels = try XCTUnwrap(app.pixels(text), "\(mode): the message body was not sampled")
                let brightness = pixels.map { $0.reduce(0, +) / 3 }
                XCTAssertGreaterThan(brightness.max()! - brightness.min()!, 100, "\(mode): no text ink in the message body")
                XCTAssertNil(app.ink(text), "\(mode): message body must be the neutral standard text colour, not a tint")
            }
        }
    }

    private func label(_ app: MountedFixture, _ key: String) -> String {
        app.element(key)?.accessibilityLabel ?? ""
    }

    private func tailNode(_ app: MountedFixture, _ tail: String) -> NSObject? {
        MountedFixture.elements(in: app.top).last { $0.accessibilityLabel?.contains(tail) == true }
    }
}
