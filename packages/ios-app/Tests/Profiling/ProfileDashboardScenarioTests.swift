import Foundation
import SwiftUI
import XCTest
@testable import TronMobile

/// Dashboard scenarios for `scripts/tron-profile ios`: the production
/// `SessionShellView` over a catalog the real `AppModel` loaded through
/// `session.list`, with `session.summary` events delivered through the real
/// `GatewayClient` at a scripted cadence.
@MainActor
final class ProfileDashboardScenarioTests: XCTestCase {
    /// Three running sessions send the Gateway's per-session summary heartbeat
    /// every 10 s, staggered; the other 57 rows are idle.
    func testIdleDashboard() throws {
        try profileScenario("idle-dashboard", defaultWindow: .seconds(30)) { _ in
            try await ProfileDashboardRun.make(activeSessions: 3, interval: .seconds(10), appendsMessages: false)
        }
    }

    /// Five running sessions each publish a summary at snapshot rate (a
    /// canonical append every 750 ms, two per tool call).
    func testSummaryStorm() throws {
        try profileScenario("summary-storm", defaultWindow: .seconds(15)) { _ in
            try await ProfileDashboardRun.make(activeSessions: 5, interval: .milliseconds(750), appendsMessages: true)
        }
    }
}

@MainActor
final class ProfileDashboardRun: ProfileScenarioRun {
    static let sessionCount = 60
    static let workspaceCount = 6

    private let fixture: ProfileGatewayFixture
    private let activeSessions: Int
    private let interval: Duration
    private let appendsMessages: Bool
    private let origin: Date
    private var sessions: [SessionSummary]
    private var host: UIHostingController<AnyView>?
    private var finalRevisions: [Int] = []

    private init(fixture: ProfileGatewayFixture, activeSessions: Int, interval: Duration, appendsMessages: Bool) {
        self.fixture = fixture
        self.activeSessions = activeSessions
        self.interval = interval
        self.appendsMessages = appendsMessages
        origin = Date()
        let names = ["Review the pull request", "Plan the release", "Fix the flaky test", "Explore the design", "Refactor storage"]
        sessions = (0..<Self.sessionCount).map { index in
            let active = index < activeSessions
            return SessionSummary(
                id: String(format: "profile-session-%02d", index),
                name: "\(names[index % names.count]) \(index)",
                cwd: "/workspace/project-\(index % Self.workspaceCount)",
                parentSessionId: nil,
                createdAt: GatewayTimestamp.preciseString(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 600)),
                updatedAt: GatewayTimestamp.preciseString(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 600 + 300)),
                // Running rows show a live elapsed clock; start it 90 s before
                // the scenario so every run shows the same label cadence.
                activeSince: active ? GatewayTimestamp.preciseString(from: Date().addingTimeInterval(-90)) : nil,
                messageCount: 12 + index,
                firstMessage: "Deterministic dashboard fixture row \(index)",
                phase: active ? .running : .idle,
                summaryRevision: 1
            )
        }
    }

    static func make(activeSessions: Int, interval: Duration, appendsMessages: Bool) async throws -> ProfileDashboardRun {
        ProfileScenarioLedger.shared.reset()
        ProfileScenarioLedger.shared.add("summaries.delivered", 0)
        let fixture = try ProfileGatewayFixture()
        let run = ProfileDashboardRun(fixture: fixture, activeSessions: activeSessions, interval: interval, appendsMessages: appendsMessages)
        do {
            let listed = try JSONValue.encode(run.sessions)
            fixture.handle("session.list") { _ in .object(["sessions": listed, "listRevision": .number(1)]) }
            try await fixture.connect()
            let outcome = await fixture.model.refreshSessions()
            guard outcome == .published else {
                throw ProfileScenarioError.notReady("session.list did not publish the fixture catalog (\(outcome))")
            }
            run.host = try fixture.mount(SessionShellView())
        } catch {
            await fixture.teardown()
            throw error
        }
        return run
    }

    func ready() async throws {
        guard let view = host?.view else { throw ProfileScenarioError.notReady("dashboard is not mounted") }
        try await profileWaitUntil("dashboard shows the \(Self.sessionCount)-session catalog") {
            fixture.model.sessions.count == Self.sessionCount
                && profileViews(UIButton.self, in: view).contains { $0.accessibilityIdentifier == "dashboard.menu" }
        }
        // Let the initial reveal, first layout and mount-time reads finish so
        // the window measures steady state rather than opening.
        try await Task.sleep(for: .seconds(2))
    }

    /// Session `j` publishes at `interval * (k + (j + 1) / activeSessions)`.
    private func schedule(window: Duration) -> [(offset: Duration, session: Int)] {
        var events: [(Duration, Int)] = []
        var cycle = 0
        while true {
            var added = false
            for session in 0..<activeSessions {
                let offset = interval * cycle + interval * (session + 1) / activeSessions
                if offset < window { events.append((offset, session)); added = true }
            }
            if !added { break }
            cycle += 1
        }
        return events.sorted { $0.0 < $1.0 }
    }

    func workload(window: Duration) async throws {
        let start = ContinuousClock.now
        let events = schedule(window: window)
        var revisions = Array(repeating: 1, count: activeSessions)
        for (offset, index) in events {
            try await profileSleep(until: offset, from: start)
            revisions[index] += 1
            let session = sessions[index]
            let update = SessionSummaryUpdate(
                sessionId: session.id,
                summaryRevision: revisions[index],
                phase: .running,
                name: session.name,
                updatedAt: GatewayTimestamp.preciseString(from: origin.addingTimeInterval(offset.profileSeconds)),
                activeSince: session.activeSince,
                messageCount: session.messageCount + (appendsMessages ? revisions[index] - 1 : 0),
                firstMessage: session.firstMessage
            )
            try await fixture.deliver(topic: "session.summary", sessionID: nil, payload: JSONValue.encode(update))
            ProfileScenarioLedger.shared.add("summaries.delivered")
        }
        try await profileSleep(until: window, from: start)
        finalRevisions = revisions
    }

    func verify() async throws {
        for (index, revision) in finalRevisions.enumerated() where revision > 1 {
            let id = sessions[index].id
            guard fixture.model.sessions.first(where: { $0.id == id })?.summaryRevision == revision else {
                throw ProfileScenarioError.workloadDiverged("\(id) did not reach summary revision \(revision)")
            }
        }
    }

    var surface: UIView? { host?.view }

    func teardown() async {
        await fixture.teardown()
    }
}
