import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ManageSheetsThemeViewTests: ShuffledTestCase {
    func testFirstOpenHomeThinkingAndContextExposeUsableSliders() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "Thinking")
            try await app.activate("Thinking")
            var editor: NSObject?
            try await app.until("the Thinking editor") {
                editor = app.element("settings-choice-slider")
                return editor != nil
            }
            let frame = try XCTUnwrap(editor).accessibilityFrame
            XCTAssertTrue(app.window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
                          "First-open editor must accept input, not remain an empty capsule: \(frame)")
            XCTAssertGreaterThan(frame.width, 100)
        }
    }

    func testManageSessionRowsTitleTheirSheetsInTheSheetTheme() async throws {
        for dark in [false, true] {
            try await mounted(["-tron-session-configuration-fixture", "-settings-scope-review", "-manage-session-review",
                               "-fixture-appearance", dark ? "dark" : "light"]) { app in
                let mode = dark ? "dark" : "light"
                try await app.activate("Stop session")
                try await app.until("Manage Session opens") { app.element("session-usage-summary") != nil }
                try await app.expandTopSheet()
                let theme = try await titleInk(app, "Manage Session")
                for label in ["Workspace", "Instructions", "Session History", "Subagent History"] {
                        _ = try await revealed(app, label)
                    assertInk(try await app.inked("\(label) row icon") { app.element(label).map(leading) }, theme,
                              "\(label) row icon (\(mode))")
                    try await app.activate(label)
                    assertInk(try await titleInk(app, label), theme, "\(label) sheet title (\(mode))")
                    try await app.activate("Done")
                    try await app.until("Manage Session returns") { app.navigationTitle("Manage Session") != nil }
                }
            }
        }
    }

    func testManageHomeRowsTitleTheirSheetsInTheSheetTheme() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            let theme = try await titleInk(app, "Manage Home")
            for (id, done) in [("home-manage-profile", "home-sheet-done-profile"), ("home-manage-memory-browser", "home-sheet-done-memory"),
                               ("home-manage-chapters", "home-sheet-done-chapters"), ("home-manage-tasks", "home-sheet-done-tasks")] {
                let row = try await revealed(app, id)
                let fullLabel = row.accessibilityLabel ?? id
                let label = fullLabel.components(separatedBy: ", ").first ?? fullLabel
                assertInk(try await app.inked("\(label) row icon") { app.element(id).map(leading) }, theme, "\(label) row icon")
                try await app.activate(id)
                try await app.until("\(id) opens") { app.element(done) != nil }
                assertInk(try await titleInk(app, label), theme, "\(label) sheet title")
                try await app.activate(done)
                try await app.until("Manage Home returns") { app.navigationTitle("Manage Home") != nil }
            }
        }
    }

    func testInstructionsRowsKeepTheirSummaryOnTheTitleLine() async throws {
        let instructions = ["-tron-agent-instructions-fixture"]
        try await mounted(instructions) { app in
            try await app.until("the instructions sections") { app.element("agent-instructions-section-preamble") != nil }
            try await app.expandTopSheet()
            let theme = try await titleInk(app, "Instructions")
            for (id, summary) in Self.summaries {
                let row = try await revealed(app, "agent-instructions-section-\(id)")
                XCTAssertTrue(app.window.bounds.contains(row.accessibilityFrame), "\(id)\n\(app.tree())")
                XCTAssertTrue(row.accessibilityLabel?.contains(summary) == true, "\(id) shows its summary: \(row.accessibilityLabel ?? "")")
                assertInk(try await app.inked("\(id) number") { app.element("agent-instructions-section-\(id)").map(leading) },
                          theme, "\(id) number")
            }
            XCTAssertTrue(app.element("agent-instructions-section-tron")?.accessibilityLabel?.contains("Each turn") == true)
        }
        try await mounted(instructions, contentSize: .accessibilityExtraExtraExtraLarge) { app in
            try await app.until("the instructions sections") { app.element("agent-instructions-section-preamble") != nil }
            for (id, summary) in Self.summaries {
                let row = try await revealed(app, "agent-instructions-section-\(id)")
                let frame = row.accessibilityFrame
                XCTAssertTrue(row.accessibilityLabel?.contains(summary) == true, "\(id) at XXXL: \(row.accessibilityLabel ?? "")")
                XCTAssertLessThanOrEqual(frame.maxX, app.window.bounds.maxX, "\(id) stays within the screen at XXXL")
                XCTAssertGreaterThan(frame.height, 56, "\(id)'s summary moves below its title at XXXL")
            }
        }
    }

    private static let summaries = [("preamble", "Built into Pi"), ("tools", "3 tools"), ("rules", "3 rules · 1 from tools"),
                                    ("cwd", "~/Workspace/project")]

    private func titleInk(_ app: MountedFixture, _ title: String) async throws -> [Double] {
        try await app.inked("\(title)'s title") {
            app.navigationTitle(title).map(\.accessibilityFrame).flatMap { app.window.bounds.contains($0) ? $0 : nil }
        }
    }

    private func leading(_ row: NSObject) -> CGRect {
        var area = row.accessibilityFrame
        area.size.width = 56
        return area
    }

    private func assertInk(_ ink: [Double], _ theme: [Double], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let hue = { (color: [Double]) in color.map { $0 / max(color.max() ?? 1, 0.01) } }
        let distance = zip(hue(ink), hue(theme)).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(distance, 0.15, "\(what) \(ink) is not the sheet theme \(theme)", file: file, line: line)
    }
}
