import Foundation
import Testing
@testable import TronMobile

@Suite("Session summary presentation")
struct SessionSummaryPresentationTests {
    private func session(
        _ id: String,
        kind: SessionSummary.Kind = .user,
        parent: String? = nil,
        updatedAt: String = "2026-01-01T00:00:00Z",
        phase: SessionPhase = .idle
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            name: id,
            cwd: "/tmp/\(id)",
            kind: kind,
            parentSessionId: parent,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            messageCount: 1,
            firstMessage: id,
            phase: phase
        )
    }

    @Test("dashboard activity timestamp is relative")
    func relativeTimestamp() {
        let now = Date(timeIntervalSince1970: 10_000)
        let updated = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2 * 60 * 60))
        let session = SessionSummary(
            id: "session",
            name: "Session",
            cwd: "/tmp/project",
            parentSessionId: nil,
            createdAt: updated,
            updatedAt: updated,
            messageCount: 1,
            firstMessage: "hello",
            phase: .idle
        )

        #expect(session.relativeActivityDescription(relativeTo: now).contains("2"))
    }

    @Test("recency ordering compares parsed instants instead of ISO text precision")
    func parsedRecencyOrdering() {
        let wholeSecond = session("whole", updatedAt: "2026-01-01T00:00:00Z")
        let laterFraction = session("fraction", updatedAt: "2026-01-01T00:00:00.900Z")
        let equivalentFraction = session("equivalent", updatedAt: "2026-01-01T00:00:00.000Z")

        #expect(SessionSummary.orderedByRecency([wholeSecond, laterFraction]).map(\.id) == ["fraction", "whole"])
        #expect(SessionSummary.orderedByRecency([wholeSecond, equivalentFraction]).map(\.id) == ["equivalent", "whole"])
    }

    @Test("relative activity changes as the dashboard clock advances")
    func relativeTimestampAges() {
        let value = session("aging", updatedAt: "2026-01-01T00:00:00Z")
        let oneMinute = GatewayTimestamp.parse("2026-01-01T00:01:00Z")!
        let twoHours = GatewayTimestamp.parse("2026-01-01T02:00:00Z")!

        #expect(value.relativeActivityDescription(relativeTo: oneMinute)
            != value.relativeActivityDescription(relativeTo: twoHours))
        #expect(DashboardActivityClock.refreshInterval == 30)
    }

    @Test("missing kind decodes as a user session")
    func legacyKindCompatibility() throws {
        let json = """
        {"id":"legacy","name":null,"cwd":"/tmp/project","parentSessionId":null,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","messageCount":1,"firstMessage":"hello","phase":"idle","summaryRevision":0}
        """
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
        #expect(decoded.kind == .user)
        #expect(SessionSummary.dashboardSessions([decoded]).map(\.id) == ["legacy"])
    }

    @Test("equal session IDs from different gateways retain distinct dashboard identities")
    func profileQualifiedIdentity() {
        let first = session("same").withGatewaySource(id: "production", label: "Mac")
        let second = session("same").withGatewaySource(id: "dev", label: "Mac (Dev)")
        #expect(first.id == second.id)
        #expect(first.dashboardID != second.dashboardID)
    }

    @Test("dashboard hides classified subagents but retains ordinary user forks")
    func dashboardVisibility() {
        let parent = session("parent")
        let fork = session("fork", parent: "parent")
        let child = session("child", kind: .subagent, parent: "parent")
        #expect(SessionSummary.dashboardSessions([parent, fork, child]).map(\.id) == ["parent", "fork"])
    }
}
