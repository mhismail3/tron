import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ToolSheetsReadablePayloadViewTests: ShuffledTestCase {
    func testSearchAndDelegateSeparateReadableContentFromTechnicalPayloads() async throws {
        for scenario in ["search", "delegate"] {
            try await mounted(["-tron-tool-sheets-polish-fixture", "-polish-scenario", scenario,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
                @MainActor func labels() -> [NSObject] { MountedFixture.elements(in: app.top) }
                @MainActor func text(_ value: String) -> Bool {
                    labels().contains {
                        let label = $0.accessibilityLabel ?? ""
                        return !$0.accessibilityTraits.contains(.button) && (label == value || label.hasPrefix("\(value), "))
                    }
                }
                @MainActor func row(_ title: String) -> String { app.element("home-tool-row-\(title)")?.accessibilityLabel ?? "" }
                try await app.until("the \(scenario) sheet") { app.element("Technical details") != nil }
                if scenario == "search" {
                    XCTAssertTrue(text("photo upload composer readiness"), app.tree())
                    XCTAssertTrue(text("Photo attachments and Send readiness"), app.tree())
                    XCTAssertTrue(labels().contains { $0.accessibilityLabel?.contains("The attachment coordinator owns preparation.") == true }, app.tree())
                } else {
                    let reason = "iOS UI work needing careful ownership and presentation judgment."
                    try await app.until("the delegate rows") { app.element("home-tool-row-Model") != nil && app.element("home-tool-row-Reason") != nil }
                    XCTAssertTrue(row("Model").contains("explicit"), row("Model"))
                    XCTAssertFalse(row("Model").contains(reason))
                    XCTAssertFalse(row("Thinking").contains(reason))
                    XCTAssertTrue(row("Reason").contains(reason), row("Reason"))
                    XCTAssertFalse(labels().contains { $0.accessibilityLabel?.contains("Delegated photo-readiness to worker-session") == true },
                                   "Raw admission prose belongs outside the custom Task section")
                    try await app.until("the subagent model rows") {
                        labels().contains { $0.accessibilityLabel?.contains("Weekly usage 97%") == true }
                    }
                    XCTAssertNotNil(app.element("home-tool-text-brief"), app.tree())
                }
                try await app.activate("Technical details")
                var request: NSObject?
                try await app.until("the request JSON row") {
                    request = labels().last {
                        $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.hasPrefix("Inspect Request JSON,") == true
                    }
                    return request != nil
                }
                guard request?.accessibilityActivate() == true else { throw FixtureNotReady(description: "Request JSON refused activation") }
                try await app.until("the Request JSON sheet") { app.navigationTitle("Request JSON") != nil }
                let requested = scenario == "search" ? "photo upload composer readiness" : "photo-readiness"
                try await app.until("the exact request") {
                    labels().contains {
                        $0.accessibilityLabel?.contains(requested) == true || ($0 as? UITextView)?.text.contains(requested) == true
                    }
                }
            }
        }
    }
}
