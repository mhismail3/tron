import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ToolSummaryTintViewTests: ShuffledTestCase {
    func testRestingTintFollowsCanonicalLatestInvocation() async throws {
        for mode in ["light", "dark"] {
            for scenario in ["recovered", "latest-failed", "clean", "cross-group"] {
                try await mounted(scenario, mode: mode) { app, chip in
                    XCTAssertEqual(chip.accessibilityLabel,
                                   scenario == "clean" ? "3 tools, Completed, 7.5s" : "3 tools, 1 failed, 7.5s")
                    try await verifyInk(app, chip: chip, expected: scenario == "latest-failed" ? .error : .tool,
                                        name: "\(scenario)-\(mode)")
                    try await openLatest(app, chip: chip, scenario: scenario,
                                         contains: scenario == "latest-failed" ? "Failed" : "Completed")
                }
            }
        }
    }

    func testActiveTintAndProgressArePreserved() async throws {
        for scenario in ["active-clean", "active-failed"] {
            try await mounted(scenario, mode: "dark") { app, chip in
                let label = chip.accessibilityLabel ?? ""
                XCTAssertTrue(label.contains(scenario == "active-failed" ? "1 failed" : "In progress"), label)
                try await verifyInk(app, chip: chip, expected: scenario == "active-failed" ? .error : .warning, name: scenario)
                try await openLatest(app, chip: chip, scenario: scenario, contains: "Invocation")
            }
        }
    }

    private enum Ink { case tool, error, warning }

    private func mounted(_ scenario: String, mode: String,
                         _ body: (MountedFixture, NSObject) async throws -> Void) async throws {
        try await mounted(["-tron-subagent-parity-fixture", "-tool-summary-tint", scenario, "-\(mode)"]) { app in
            var chip: NSObject?
            try await app.until("the tool summary chip") {
                chip = app.labelled("3 tools,")
                return chip != nil
            }
            try await body(app, chip!)
        }
    }

    private func openLatest(_ app: MountedFixture, chip: NSObject, scenario: String, contains: String) async throws {
        guard chip.accessibilityActivate() else { throw FixtureNotReady(description: "the tool summary chip refused activation") }
        try await app.until("the tool run sheet opens") { app.element("Done") != nil }
        let latest = app.element("tool-run-summary-tint-\(scenario)-2")
        XCTAssertNotNil(latest, app.tree())
        XCTAssertTrue(latest?.accessibilityLabel?.contains(contains) == true, latest?.accessibilityLabel ?? "")
    }

    private func verifyInk(_ app: MountedFixture, chip: NSObject, expected: Ink, name: String) async throws {
        let frame = chip.accessibilityFrame
        let title = CGRect(x: frame.minX + 28, y: frame.midY - 9, width: 54, height: 18)
        _ = try await app.still("\(name) title ink") { app.chroma(title, range: 60)?.ink }
        let measured = app.chroma(title, range: 60)
        XCTAssertGreaterThan(measured?.count ?? 0, 20, "Must observe actual colored title ink")
        guard let ink = measured?.ink else { return }
        print("TOOL_SUMMARY_INK \(name) \(ink)")
        switch expected {
        case .tool:
            XCTAssertGreaterThan(ink[1], 0.8, "\(name): default tool ink must be green")
            XCTAssertLessThan(ink[0], 0.4, "\(name): historical failure must not leave resting title red")
        case .error:
            XCTAssertGreaterThan(ink[0], 0.8, "\(name): latest failure retains red")
            XCTAssertLessThan(ink[1], 0.25, "\(name): red, not active amber")
        case .warning:
            XCTAssertGreaterThan(ink[0], 0.8, "\(name): active amber")
            XCTAssertGreaterThan(ink[1], 0.4, "\(name): active amber, not error red")
        }
    }
}
