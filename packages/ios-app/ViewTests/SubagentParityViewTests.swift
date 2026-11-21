import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SubagentParityViewTests: ShuffledTestCase {
    func testHomeChipLabelCaptures() async throws {
        let chips = ["Manage task, Completed, 42ms", "Send notification, Completed, 18ms", "Worker · Simplify Home chip labels, Reported"]
        for scheme in ["light", "dark"] {
            try await mounted(["-tron-subagent-parity-fixture", "-home-chip-labels", "-\(scheme)"]) { app in
                try await app.until("the assistant reply and its chips") {
                    reply(app, "The requested changes are ready for review.") && chips.allSatisfy { app.button($0) != nil }
                }
                XCTAssertTrue(nodes(app) { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("Tron Home ·") == true }.isEmpty)
                XCTAssertTrue(nodes(app) { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("Tron Notify ·") == true }.isEmpty)
            }
        }
    }

    func testHistoricalSessionPills() async throws {
        try await mounted(["-tron-subagent-parity-fixture", "-dark", "-historical"]) { app in
            try await app.until("the needs-attention pill") { app.button("Subagent, Needs Attention") != nil }
            XCTAssertNil(app.button("Extension content"), "Historic classification belongs to Gateway, not npm parsing")
            try await verifyPills(app)
        }
    }

    func testPendingWakePreflightJourney() async throws {
        try await verifyRuntimeWake("pending-wake")
    }

    func testQueuedWakeSteerJourney() async throws {
        try await verifyRuntimeWake("queued-wake")
    }

    func testQueuedMaintainerRemainsVisible() async throws {
        for scheme in ["light", "dark"] {
            try await mounted(["-tron-subagent-parity-fixture", "-\(scheme)", "-queued-wake", "-queued-maintainer"]) { app in
                try await app.until("the maintainer's queued message") { app.staticText("Maintainer queued message") != nil }
                XCTAssertNil(app.staticText("Subagent updates above."))
            }
        }
    }

    func testHistoryQueuedPausedResumedAndTerminalExecutions() async throws {
        for outcome in ["completed", "failed", "stopped"] {
            try await mounted(["-tron-subagent-parity-fixture", "-history-grouping", "-history-lifecycle", "-history-\(outcome)", "-dark"]) { app in
                try await app.activate("Subagent History")
                try await app.until("the worker row") { app.button("subagent-row-worker") != nil }
                try await app.expandTopSheet()
                let stages = [("worker", "Queued", true), ("worker", "Running", true),
                              ("worker", "Pausing…", true), ("worker", "Paused", false),
                              ("resumed", "Queued", true), ("resumed", "Running", true),
                              ("resumed", outcome.capitalized, false)]
                for (index, stage) in stages.enumerated() {
                    if index > 0 { try await app.activate("Advance lifecycle") }
                    try await assertHistoryRow(app, id: stage.0, status: stage.1, active: stage.2)
                    try await assertHistoryRow(app, id: "completed", status: "Completed", active: false)
                    if index >= 4 {
                        try await assertHistoryRow(app, id: "worker", status: "Paused", active: false)
                        XCTAssertEqual(rows(app) { $0.hasPrefix("subagent-row-") }.count, 3)
                    }
                }
            }
        }
    }

    private func verifyRuntimeWake(_ stage: String) async throws {
        for scheme in ["light", "dark"] {
            try await mounted(["-tron-subagent-parity-fixture", "-\(scheme)", "-\(stage)"]) { app in
                try await app.until("the needs-attention pill") { app.button("Subagent, Needs Attention") != nil }
                XCTAssertNil(app.staticText("Subagent updates above."),
                             "An internal input must have no user-position bubble before canonical binding: \(stage)")
                XCTAssertNil(app.button("Subagent, Update"), "A hidden wake must not gain a pill")
            }
        }
    }

    private func verifyPills(_ app: MountedFixture) async throws {
        for (label, body) in [
            ("Subagent, Progress Update", "Worker has finished discovery."),
            ("Subagent, Child Update", "Reviewer child result: no blockers."),
            ("Subagent, Needs Attention", "May the worker proceed?")
        ] {
            try await app.until("the \(label) pill") { app.button(label) != nil }
            XCTAssertEqual(nodes(app) { $0.accessibilityTraits.contains(.button) && ($0.accessibilityLabel == label || MountedFixture.identifier($0) == label) }.count, 1, "One pill per subagent message")
            XCTAssertNil(app.staticText("Subagent updates above."), "Wake must not be a user bubble")
            try await app.activate(label)
            try await app.until("the \(label) details") { app.staticText(body) != nil }
            XCTAssertNil(app.staticText("Unknown source"))
            XCTAssertNil(app.staticText("Context received"))
            try await app.activate("Done")
        }
        XCTAssertNil(app.button("Subagent, Update"), "Internal wake must not add a pill")
    }

    private func assertHistoryRow(_ app: MountedFixture, id: String, status: String, active: Bool) async throws {
        try await app.until("\(id) reads \(status)") { rowValue(app, "subagent-row-\(id)").hasPrefix("\(status),") }
        XCTAssertEqual(rows(app) { $0 == "subagent-row-\(id)" }.count, 1)
        if !active {
            XCTAssertFalse(rowValue(app, "subagent-row-\(id)").contains("LIVE OUTPUT"))
        }
    }

    private func reply(_ app: MountedFixture, _ text: String) -> Bool {
        !nodes(app) {
            MountedFixture.identifier($0) == "chat.assistant.selectable-text" && ($0 as? UITextView)?.text.contains(text) == true
        }.isEmpty
    }

    private func nodes(_ app: MountedFixture, _ match: (NSObject) -> Bool) -> [NSObject] {
        MountedFixture.elements(in: app.top).filter(match)
    }

    private func rows(_ app: MountedFixture, _ match: (String) -> Bool) -> [NSObject] {
        nodes(app) { $0.accessibilityTraits.contains(.button) && match(MountedFixture.identifier($0) ?? "") }
    }

    private func rowValue(_ app: MountedFixture, _ id: String) -> String {
        rows(app) { $0 == id }.first?.accessibilityValue ?? ""
    }
}
