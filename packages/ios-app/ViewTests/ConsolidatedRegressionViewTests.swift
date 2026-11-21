import XCTest
@testable import TronMobile

@MainActor
final class ConsolidatedRegressionViewTests: ShuffledTestCase {
    func testMemoryCountIsTheTagWithoutDuplicateSubtext() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-memory-redesign"]) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-memory-browser")
            try await app.activate("home-manage-memory-browser")
            try await app.until("Memory opens") { app.element("home-memory-row-39") != nil }
            try await app.expandTopSheet()
            let row = try await revealed(app, "home-memory-summary-32-2")
            let tags = MountedFixture.elements(in: row).filter { $0.accessibilityLabel?.hasPrefix("Summary of ") == true }
            XCTAssertEqual(tags.count, 1, "The count is presented once as the summary tag")
            XCTAssertFalse(MountedFixture.elements(in: row).contains { $0.accessibilityLabel == "Summary" },
                           "No count-less duplicate attribution tag")
            try await app.activate("home-memory-summary-32-2")
            try await app.until("the summary detail opens") { app.element("home-memory-summary-detail") != nil }
        }
    }

    func testSessionModelCardUsesFencedWritesAndThinkingRevert() async throws {
        try await mounted(["-tron-session-configuration-fixture"]) { app in
            try await openSession(app)
            try await app.activate("Release terminal settlement")
            try await app.until("the model card rows") { card(app, "Thinking") && card(app, "Context Window") }
            try await tap(app, "settings-row-model.thinking_role_chat_-reset")
            try await app.until("Thinking reverts to High") { thinking(app)?.accessibilityValue == "High" }
            try await app.activate("manage-model-switch")
            try await app.pressButton(containing: "Alternative Model")
            try await app.until("Only the acknowledged fenced session choice is published") { card(app, "Alternative Model") }
            try await app.until("Preview must not count as a mutation") { app.staticText("Model requests: 1") != nil }
        }
    }

    private func openSession(_ app: MountedFixture) async throws {
        try await app.activate("Stop session")
        try await app.until("Manage Session opens") { app.navigationTitle("Manage Session") != nil }
        try await app.expandTopSheet()
    }

    private func cleanTree(_ app: MountedFixture) -> String? {
        MountedFixture.elements(in: app.top).last {
            $0.accessibilityLabel?.contains("Working tree clean") == true && app.onScreen($0)
        }?.accessibilityLabel
    }

    private func tap(_ app: MountedFixture, _ key: String) async throws {
        _ = try await revealed(app, key)
        try await app.activate(key)
    }

    private func card(_ app: MountedFixture, _ text: String) -> Bool {
        guard let node = app.element("session-model-summary") else { return false }
        return MountedFixture.elements(in: node).contains { $0.accessibilityLabel == text }
    }

    private func thinking(_ app: MountedFixture) -> NSObject? {
        app.element("session-model-summary").flatMap { node in
            MountedFixture.elements(in: node).last { MountedFixture.identifier($0) == "settings-choice-control" }
        }
    }
}
