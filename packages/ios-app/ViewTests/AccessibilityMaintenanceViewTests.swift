import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class AccessibilityMaintenanceViewTests: ShuffledTestCase {
    func testMaintenanceActionGeometry() async throws {
        try await mounted(["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
            try await app.activate("Maintenance")
            let frames = try await actionFrames(app, ["Rebuild from Source", "Roll Back", "Restart", "Disable", "Forget Server"])
            XCTAssertEqual(frames[0].minX, frames[2].minX, accuracy: 1)
            XCTAssertEqual(frames[1].minX, frames[3].minX, accuracy: 1)
            XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
            XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
            XCTAssertEqual(frames[2].minY, frames[3].minY, accuracy: 1)
            XCTAssertGreaterThan(frames[2].minY, frames[0].maxY)
            XCTAssertGreaterThan(frames[4].width, frames[0].width * 1.5)
            XCTAssertGreaterThan(frames[4].minY, frames[2].maxY)
        }
    }

    func testLoneMaintenanceActionUsesFullContentWidth() async throws {
        for arguments in [[], ["-fixture-light"], ["-fixture-large-type"]] {
            try await mounted(["-tron-accessibility-fixture", "-fixture-lone-maintenance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                              + arguments) { app in
                try await app.activate("Maintenance")
                let labels = ["Rebuild from Source", "Restart", "Disable", "Forget Server"]
                let frames = try await actionFrames(app, labels)
                XCTAssertEqual(frames[2].minX, frames[3].minX, accuracy: 1)
                XCTAssertEqual(frames[2].maxX, frames[3].maxX, accuracy: 1, "Disable must reach the same trailing edge as Forget Server")
                XCTAssertEqual(frames[2].width, frames[3].width, accuracy: 1)
                XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
                XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
                XCTAssertGreaterThan(frames[2].minY, max(frames[0].maxY, frames[1].maxY))
                XCTAssertGreaterThan(frames[3].minY, frames[2].maxY)
                for label in labels {
                    let frame = try XCTUnwrap(app.button(label)).accessibilityFrame
                    XCTAssertTrue(app.window.bounds.contains(frame), "\(label) is on screen")
                    XCTAssertGreaterThanOrEqual(frame.height, 44)
                }
            }
        }
    }

    func testServerInfoRowsAndDone() async throws {
        try await mounted(["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
            try await app.activate("Gateway Server Info")
            let facts = ["Machine, Mac", "Gateway, 1", "Agent runtime, 2", "Protocol, 9",
                         "Restart supervision, Managed LaunchAgent", "Source revision, source-revision",
                         "Runtime epoch, runtime-epoch", "Payload identity, payload-identity"]
            try await app.until("the server facts") { facts.allSatisfy { app.staticText($0) != nil } }
            for label in facts {
                XCTAssertNil(app.button(label), "Facts are not navigation targets")
            }
            XCTAssertEqual(MountedFixture.elements(in: app.top).filter {
                ($0.accessibilityLabel == "Done" || MountedFixture.identifier($0) == "Done") && $0.accessibilityTraits.contains(.button)
            }.count, 1)
            try await app.activate("Done")
            try await app.until("Gateway Server Info returns") { app.button("Gateway Server Info") != nil }
            let back = try XCTUnwrap(app.button("Gateway Server Info"))
            XCTAssertTrue(app.onScreen(back))
        }
    }

    func testMacReplacementJournalRows() async throws {
        for arguments in [[], ["-fixture-large-type"]] {
            try await mounted(["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments) { app in
                try await app.activate("Mac Replacement")
                let steps = ["Full signed build", "Rolled back", "Preflight", "Build signed app", "Verify signature",
                             "Stop running workers", "Stop Gateway", "Swap app", "Start new app", "Verify Gateway", "Finish"]
                try await app.until("the journal rows") { steps.allSatisfy { row(app, $0) != nil } }
                var resume: NSObject?
                try await app.until("the stopped worker's Resume") {
                    resume = MountedFixture.elements(in: app.top).last {
                        $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.hasSuffix("Resume iPhone SSH terminal") == true
                    }
                    return resume != nil
                }
                try await app.reveal(resume!)
                XCTAssertTrue(app.onScreen(resume!), "a stopped worker offers Resume")
                XCTAssertNotNil(row(app, "Failed at Start new app"))
                XCTAssertNotNil(row(app, "Previous app restored"))
                XCTAssertFalse(MountedFixture.elements(in: app.top).contains {
                    $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("Resume Settings polish") == true
                }, "a resumed worker offers no second Resume")
                XCTAssertTrue(row(app, "Settings polish")?.accessibilityLabel?.contains("Resumed in place") == true)
            }
        }
    }

    func testJSONTypedButtonsOpenTheirCompleteValues() async throws {
        try await mounted(["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
            try await app.activate("Structured JSON")
            let rows = ["Active Async Capacity, Object, 2 fields", "Mode, Text, single", "Results, List, 0 items"]
            try await app.until("the JSON rows") { rows.allSatisfy { app.button($0) != nil } }
            XCTAssertNotNil(app.staticText("DETAILS"))
            try await app.activate("Active Async Capacity, Object, 2 fields")
            try await app.until("the nested Max row") { app.button("Max, Number, 4") != nil }
            XCTAssertNotNil(app.button("Mode, Text, single"))
        }
    }

    func testActivityValuesUpdateInTheSamePresentedSheet() async throws {
        for arguments in [[], ["-fixture-light", "-fixture-large-type"]] {
            try await mounted(["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments) { app in
                try await app.activate("Session Activity")
                try await app.until("the worker row") { app.button("worker") != nil }
                try await waitForValue(app, "LIVE OUTPUT: Inspecting the source files.")
                XCTAssertEqual(MountedFixture.elements(in: app.top).filter {
                    $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.hasPrefix("worker") == true
                }.count, 1)
                XCTAssertTrue(value(app).contains("Asynchronous"))
                let row = try XCTUnwrap(app.button("worker"))
                XCTAssertGreaterThan(row.accessibilityFrame.width, 0)
                XCTAssertGreaterThanOrEqual(row.accessibilityFrame.minX, app.window.bounds.minX)
                XCTAssertLessThanOrEqual(row.accessibilityFrame.maxX, app.window.bounds.maxX)
                let scroll = try XCTUnwrap(MountedFixture.views(UIScrollView.self, in: app.top).first {
                    app.window.bounds.intersects($0.accessibilityFrame)
                })
                let originalFrame = scroll.accessibilityFrame

                try await app.activate("Update fixture output")
                try await waitForValue(app, "Latest check passed.")
                XCTAssertFalse(value(app).contains("Inspecting the source files."))
                XCTAssertFalse(value(app).contains("Old output"))
                XCTAssertTrue(value(app).contains("First check passed."))
                XCTAssertEqual(scroll.accessibilityFrame, originalFrame, "Output must not resize the selected sheet detent")

                try await app.activate("Finish fixture output")
                try await waitForValue(app, "RESULT: All focused checks passed.")
                XCTAssertTrue(value(app).contains("Completed"))
                XCTAssertFalse(value(app).contains("LIVE OUTPUT"))
                XCTAssertEqual(scroll.accessibilityFrame, originalFrame)
            }
        }
    }

    func testDashboardActionsPresentTheirExistingDestinations() async throws {
        let destinations = [
            ("New Session", "New Session"), ("Automations", "Automations"),
            ("Settings", "Global Settings"),
        ]
        for (action, expected) in destinations {
            try await mounted(["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-fixture-dashboard"]) { app in
                try await performDashboardAction(app, action)
                try await app.until("\(expected) opens") { app.staticText(expected) != nil }
                XCTAssertFalse(MountedFixture.views(UINavigationBar.self, in: app.top).isEmpty)
            }
        }
    }

    func testKnowledgeProductIsAbsentFromDashboardAndConnectedServices() async throws {
        for variant in ["-fixture-light", "-fixture-dark", "-fixture-xxxl", "-fixture-large-type"] {
            try await mounted(["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-fixture-dashboard", variant]) { app in
                let titles = menuActionTitles(try await dashboardMenu(app))
                XCTAssertFalse(titles.contains("Knowledge"))
                for title in ["Settings", "Automations", "Apps", "New Session"] {
                    XCTAssertTrue(titles.contains(title))
                }
                try await performDashboardAction(app, "Settings")
                try await app.until("the settings links") { app.button("settings-link-MCP Servers") != nil }
                XCTAssertNil(app.button("settings-link-Connected Services"), "Retired vendor setup must not advertise removed RPCs")
                let mcp = try await revealed(app, "settings-link-MCP Servers")
                XCTAssertTrue(app.onScreen(mcp), "MCP remains a reachable, independent owner")
                try await app.activate("settings-link-MCP Servers")
                try await app.until("MCP Servers opens") { app.navigationTitle("MCP Servers") != nil }
                XCTAssertNotNil(app.button("Add Server"), "The surviving MCP destination owns its add action")
            }
        }
    }

    private func actionFrames(_ app: MountedFixture, _ labels: [String]) async throws -> [CGRect] {
        try await app.until("the maintenance actions") { labels.allSatisfy { app.button($0) != nil } }
        return labels.map { app.button($0)!.accessibilityFrame }
    }

    private func value(_ app: MountedFixture) -> String {
        (app.button("worker")?.accessibilityValue) ?? ""
    }

    private func waitForValue(_ app: MountedFixture, _ text: String) async throws {
        try await app.until("\(text) on the worker row") { value(app).contains(text) }
    }

    private func row(_ app: MountedFixture, _ title: String) -> NSObject? {
        MountedFixture.elements(in: app.top).last {
            !$0.accessibilityTraits.contains(.button)
                && ($0.accessibilityLabel == title || $0.accessibilityLabel?.hasPrefix(title + ", ") == true)
        }
    }
}
