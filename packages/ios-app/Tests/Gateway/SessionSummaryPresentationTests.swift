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
        activeSince: String? = nil,
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
            activeSince: activeSince,
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

        #expect(SessionSummary.orderedForDashboard([wholeSecond, laterFraction]).map(\.id) == ["fraction", "whole"])
        #expect(SessionSummary.orderedForDashboard([wholeSecond, equivalentFraction]).map(\.id) == ["equivalent", "whole"])
    }

    @Test("active dashboard ordering ignores live timestamp churn")
    func activeOrderingStability() {
        let olderActive = session(
            "older-active",
            updatedAt: "2026-01-01T00:10:30Z",
            activeSince: "2026-01-01T00:00:00Z",
            phase: .running
        )
        let newerActive = session(
            "newer-active",
            updatedAt: "2026-01-01T00:10:20Z",
            activeSince: "2026-01-01T00:05:00Z",
            phase: .retrying
        )
        let newestHistory = session("history", updatedAt: "2026-01-01T00:11:00Z")

        #expect(SessionSummary.orderedForDashboard([olderActive, newestHistory, newerActive]).map(\.id)
            == ["newer-active", "older-active", "history"])

        let heartbeat = session(
            "older-active",
            updatedAt: "2026-01-01T00:12:00Z",
            activeSince: olderActive.activeSince,
            phase: .running
        )
        #expect(SessionSummary.orderedForDashboard([heartbeat, newestHistory, newerActive]).map(\.id)
            == ["newer-active", "older-active", "history"])
    }

    @Test("rolling-upgrade active rows use stable identity instead of live timestamps")
    func rollingUpgradeActiveOrdering() {
        let later = session("z-active", updatedAt: "2026-01-01T00:20:00Z", phase: .running)
        let earlier = session("a-active", updatedAt: "2026-01-01T00:10:00Z", phase: .running)
        let advanced = session("z-active", updatedAt: "2026-01-01T00:30:00Z", phase: .running)

        #expect(SessionSummary.orderedForDashboard([later, earlier]).map(\.id) == ["a-active", "z-active"])
        #expect(SessionSummary.orderedForDashboard([advanced, earlier]).map(\.id) == ["a-active", "z-active"])
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
        #expect(decoded.foregroundPhase == nil)
        #expect(!decoded.hasActiveSubagents)
        #expect(!decoded.hasOnlyActiveSubagents)
        #expect(SessionSummary.dashboardSessions([decoded]).map(\.id) == ["legacy"])
    }

    @Test("summary distinguishes settled foreground from active subagents")
    func activeSubagentSummary() throws {
        let json = """
        {"id":"delegating","name":null,"cwd":"/tmp/project","kind":"user","parentSessionId":null,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:01Z","messageCount":2,"firstMessage":"delegate","phase":"running","foregroundPhase":"idle","hasActiveSubagents":true,"summaryRevision":4}
        """
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))

        #expect(decoded.foregroundPhase == .idle)
        #expect(decoded.hasActiveSubagents)
        #expect(decoded.hasOnlyActiveSubagents)
        #expect(decoded.withGatewaySource(id: "stable", label: "Mac").hasOnlyActiveSubagents)
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
