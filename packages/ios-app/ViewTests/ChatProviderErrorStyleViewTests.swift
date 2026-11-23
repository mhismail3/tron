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

    func testProviderErrorRunUpdatesLiveAndSurvivesReopen() async throws {
        try await mounted(providerErrorArguments) { app in
            try await app.until("the overloaded error run") { pill(app, ["Anthropic is overloaded"]) != nil }
            try await app.activate("Live error")
            try await app.until("the grouped error run") { pill(app, ["Anthropic is overloaded", "2 errors"]) != nil }
            try await app.activate("Settle error")
            try await app.until("the grouped error run after settle") { pill(app, ["Anthropic is overloaded", "2 errors"]) != nil }
            try await app.activate("Mixed error")
            try await app.until("the mixed error run") { pill(app, ["Provider errors", "3 errors"]) != nil }
            XCTAssertEqual(runs(app), 1)
            try await app.activate("fixture.reopen-chat")
            try await app.until("the reopened chat") { node(app, "fixture.gateway", "opens:2") != nil }
            try await app.until("the mixed error run after reopen") { pill(app, ["Provider errors", "3 errors"]) != nil }
            XCTAssertEqual(runs(app), 1)
            try await app.activate("Continue boundary")
            try await app.until("the continued transcript") { app.staticText("Continue") != nil }
            try await app.until("a second error run") { runs(app) == 2 }
        }
    }

    func testProviderErrorSheetsShowBreakdownPrettyJSONAndRawText() async throws {
        try await mounted(providerErrorArguments) { app in
            try await press(app, ["Anthropic is overloaded"])
            try await app.until("the pretty JSON body") { node(app, "chat-error-body-error-first", "\n  \"error\"") != nil }
            XCTAssertNotNil(node(app, "chat-error-body-error-first", "req_error-first"))
            XCTAssertNotNil(node(app, "chat-error-request-id-error-first", "req_error-first"))
            try await app.activate("Done")
            try await app.activate("Mixed error")
            try await app.until("the mixed error run") { pill(app, ["Provider errors"]) != nil }
            try await app.activate("Delayed error")
            try await press(app, ["Provider errors"])
            try await app.until("the two-error summary") { node(app, "chat-error-summary", "2 errors · 2 distinct errors") != nil }
            try await app.until("the raw timeout text") {
                MountedFixture.elements(in: app.top).contains {
                    (MountedFixture.identifier($0) ?? "").hasPrefix("chat-error-body-")
                        && $0.accessibilityLabel == "Request timed out after 60 seconds"
                }
            }
            try await app.until("the three-error summary") { node(app, "chat-error-summary", "3 errors · 2 distinct errors") != nil }
            XCTAssertNotNil(app.button("Done"), "Live update must keep the same sheet open")
        }
    }

    func testErrorSheetsShareStandardRowsInLightAndDark() async throws {
        for dark in [false, true] {
            try await mounted(providerErrorArguments + ["-error-style-preview"] + (dark ? ["-error-preview-dark"] : [])) { app in
                try await press(app, ["Anthropic is overloaded", "1 error"])
                try await app.until("the single error's rows") {
                    app.element("chat-error-body-error-first") != nil
                        && ["Model, ", "Type, overloaded_error", "Time, "].allSatisfy { rows(app, $0) > 0 }
                }
                try await app.activate("Done")
                for action in ["Live error", "Settle error", "Mixed error"] {
                    try await app.activate(action)
                }
                try await press(app, ["Provider errors", "3 errors"])
                try await app.until("every occurrence's full message") {
                    MountedFixture.elements(in: app.top).filter { (MountedFixture.identifier($0) ?? "").hasPrefix("chat-error-body-") }.count == 3
                }
                XCTAssertNotNil(app.element("chat-error-summary"))
                XCTAssertEqual(rows(app, "Model, "), 3, "Every occurrence uses the single error's detail rows")
            }
        }
    }

    private let providerErrorArguments = ["-tron-chat-haptics-fixture", "-chat-provider-errors"]

    private func pill(_ app: MountedFixture, _ parts: [String]) -> NSObject? {
        MountedFixture.elements(in: app.top).last { node in
            node.accessibilityTraits.contains(.button) && parts.allSatisfy { (node.accessibilityLabel ?? "").contains($0) }
        }
    }

    private func press(_ app: MountedFixture, _ parts: [String]) async throws {
        try await app.until("\(parts) is on screen") { pill(app, parts) != nil }
        XCTAssertTrue(pill(app, parts)?.accessibilityActivate() ?? false, "\(parts) activates")
    }

    private func runs(_ app: MountedFixture) -> Int {
        MountedFixture.elements(in: app.top).filter {
            $0.accessibilityTraits.contains(.button) && (MountedFixture.identifier($0) ?? "").hasPrefix("chat-error-run-")
        }.count
    }

    private func node(_ app: MountedFixture, _ identifier: String, _ text: String) -> NSObject? {
        MountedFixture.elements(in: app.top).last {
            MountedFixture.identifier($0) == identifier && ($0.accessibilityLabel ?? "").contains(text)
        }
    }

    private func rows(_ app: MountedFixture, _ prefix: String) -> Int {
        MountedFixture.elements(in: app.top).filter { ($0.accessibilityLabel ?? "").hasPrefix(prefix) }.count
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
