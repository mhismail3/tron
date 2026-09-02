import Foundation
import Testing
@testable import TronMobile

@Suite("Session process models")
struct SessionProcessModelsTests {
    @Test("legacy command shapes validate but only subagents enter presentation")
    func wireShapes() throws {
        let command = try JSONDecoder.gateway.decode(SessionProcessActivity.self, from: Data(#"""
        {
          "version":1,"processId":"process:command:abc","kind":"command","executionMode":"foreground","source":"mainAssistant",
          "lifecycle":{"version":1,"state":"running","attention":"none","sequence":2,"observedAt":"2026-01-01T00:00:02Z"},
          "visibility":"active","startedAt":"2026-01-01T00:00:00Z","title":"Command","command":"npm test","outputTail":"running","outputTruncated":false,"toolCallId":"call-1"
        }
        """#.utf8))
        #expect(SessionProcessAdmissionPolicy.admits(command))
        #expect(command.childSessionRef == nil)

        let subagent = try JSONDecoder.gateway.decode(SessionProcessActivity.self, from: Data(#"""
        {
          "version":1,"processId":"process:subagent:def","kind":"subagent","executionMode":"asynchronous","source":"delegatedAgent",
          "lifecycle":{"version":1,"state":"completed","attention":"none","sequence":4,"observedAt":"2026-01-01T00:00:02Z","terminalAt":"2026-01-01T00:00:01Z","recentUntil":"2026-01-01T00:05:01Z"},
          "visibility":"recent","title":"Scout","outputTruncated":false,"childSessionRef":"child-session-id"
        }
        """#.utf8))
        #expect(SessionProcessAdmissionPolicy.admits(subagent))
        #expect(subagent.childSessionRef == "child-session-id")
        #expect(SessionProcessProjection.sections([command, subagent]).recent.map(\.processId) == [subagent.processId])
    }

    @Test("canonical history uses the Gateway activities key")
    func historyWireShape() throws {
        let data = Data(#"""
        {
          "activities":[{
            "version":1,"processId":"process:subagent:abc","kind":"subagent","executionMode":"asynchronous","source":"delegatedAgent",
            "lifecycle":{"version":1,"state":"completed","attention":"none","sequence":0,"observedAt":"2026-01-01T00:00:01Z","terminalAt":"2026-01-01T00:00:01Z","recentUntil":"2026-01-01T00:05:01Z"},
            "visibility":"historical","title":"worker","outputTruncated":false,"toolCallId":"call-1","runId":"run-1","childSessionRef":"child-1"
          }],
          "historyRevision":"revision-1"
        }
        """#.utf8)
        let page = try JSONDecoder.gateway.decode(SessionProcessHistoryPage.self, from: data)
        #expect(page.activities.map(\.processId) == ["process:subagent:abc"])
    }

    @Test("canonical history rejects malformed rows instead of silently dropping them")
    func malformedHistoryRow() {
        let data = Data(#"""
        {
          "activities":[{
            "version":1,"processId":"process:command:abc","kind":"command","title":"incomplete"
          }],
          "historyRevision":"revision-1"
        }
        """#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.gateway.decode(SessionProcessHistoryPage.self, from: data)
        }
    }

    @Test("history projection retains more than the mounted thirty-two row cap")
    func historyProjectionCapacity() {
        let rows = (0..<50).map { index in
            makeProcess(
                state: .completed,
                visibility: .historical,
                sequence: index,
                terminalAt: "2026-01-01T00:00:01Z",
                outputTail: nil
            )
        }
        let projected = SessionProcessHistoryProjection.appending([], rows, limit: 400)
        #expect(projected.count == 50)
        #expect(Set(projected.map(\.processId)).count == 50)
    }

    @Test("subagent rows standardize the latest action and bound output to three lines")
    func rowPresentation() {
        let process = makeProcess(
            currentTool: "bash",
            currentPathBasename: "worktree.log",
            outputTail: "one\ntwo\nthree\nfour\nfive"
        )
        #expect(SessionProcessRowPresentation.latestAction(for: process) == "bash · worktree.log")
        #expect(SessionProcessRowPresentation.outputPreview(process.outputTail) == "three\nfour\nfive")
        #expect(SessionProcessRowPresentation.latestAction(for: makeProcess(
            currentTool: "bash",
            currentPathBasename: "null"
        )) == "bash")
    }

    @Test("active and recent process rows are strictly admitted")
    func admission() {
        let active = makeProcess(state: .running, visibility: .active, sequence: 2)
        #expect(SessionProcessAdmissionPolicy.admits(active))
        #expect(active.lifecycle.state.isActive)
        let recent = makeProcess(
            state: .completed, visibility: .recent, sequence: 3,
            terminalAt: "2026-01-01T00:00:01Z", recentUntil: "2026-01-01T00:05:01Z"
        )
        #expect(SessionProcessAdmissionPolicy.admits(recent))
        #expect(!recent.lifecycle.state.isActive)
        #expect(SessionProcessProjection.sections([recent, active]).active.map(\.id) == [active.id])
        #expect(SessionProcessProjection.sections([recent, active]).recent.map(\.id) == [recent.id])
    }

    @Test("subagent stop control mounts disabled before exact authority arrives")
    func stopControlVisibility() {
        #expect(ReadOnlySubagentStopControlPolicy.isVisible(
            lifecycleState: .running,
            supportsAbort: true
        ))
        #expect(!ReadOnlySubagentStopControlPolicy.isEnabled(
            lifecycleState: .running,
            hasAbortAuthority: false,
            supportsAbort: true,
            isConnected: true,
            stopRequested: false
        ))
        #expect(ReadOnlySubagentStopControlPolicy.isEnabled(
            lifecycleState: .running,
            hasAbortAuthority: true,
            supportsAbort: true,
            isConnected: true,
            stopRequested: false
        ))
        #expect(!ReadOnlySubagentStopControlPolicy.isEnabled(
            lifecycleState: .running,
            hasAbortAuthority: true,
            supportsAbort: true,
            isConnected: false,
            stopRequested: false
        ))
        #expect(!ReadOnlySubagentStopControlPolicy.isEnabled(
            lifecycleState: .running,
            hasAbortAuthority: true,
            supportsAbort: true,
            isConnected: true,
            stopRequested: true
        ))
        for terminal in [
            SessionProcessLifecycleState.completed,
            .failed,
            .stopped,
            .rejected,
            .interrupted,
        ] {
            #expect(!ReadOnlySubagentStopControlPolicy.isVisible(
                lifecycleState: terminal,
                supportsAbort: true
            ))
            #expect(!ReadOnlySubagentStopControlPolicy.isEnabled(
                lifecycleState: terminal,
                hasAbortAuthority: true,
                supportsAbort: true,
                isConnected: true,
                stopRequested: false
            ))
        }
        #expect(!ReadOnlySubagentStopControlPolicy.isVisible(
            lifecycleState: .running,
            supportsAbort: false
        ))
    }

    @Test("a mounted aggregate follows only one exact tool and run successor")
    func mountedAggregateSuccessor() {
        let selected = makeProcess(sequence: 1)
        let successor = makeProcess(sequence: 2)
        let ambiguous = makeProcess(sequence: 3)
        #expect(SessionProcessProjection.mountedActivity(
            selected: selected,
            activities: [selected, successor]
        )?.processId == selected.processId)
        #expect(SessionProcessProjection.mountedActivity(
            selected: selected,
            activities: [successor]
        )?.processId == successor.processId)
        #expect(SessionProcessProjection.mountedActivity(
            selected: selected,
            activities: [successor, ambiguous]
        ) == nil)
    }

    @Test("terminal truth and privacy bounds fail closed")
    func invalidRows() {
        #expect(!SessionProcessAdmissionPolicy.admits(makeProcess(
            state: .completed, visibility: .active, sequence: 1,
            terminalAt: "2026-01-01T00:00:01Z", recentUntil: "2026-01-01T00:05:01Z"
        )))
        #expect(!SessionProcessAdmissionPolicy.admits(makeProcess(currentPathBasename: "/private/file")))
        #expect(!SessionProcessAdmissionPolicy.admits(makeProcess(outputTail: String(repeating: "x", count: 33 * 1_024))))
    }

    @Test("snapshot process pair is atomic")
    func snapshotPair() throws {
        var snapshot = try SessionScenarioBuilder(seed: 91_001).openingTail(targetEncodedBytes: 20_000)
        let overview = SessionProcessOverview(
            revision: 4, asOf: "2026-01-01T00:00:02Z",
            activeCount: 1, recentCount: 0, problemCount: 0, visibility: .active
        )
        snapshot.processOverview = overview
        #expect(!SessionProcessAdmissionPolicy.admitsSnapshotFacts(snapshot))
        snapshot.processActivities = [makeProcess()]
        #expect(SessionProcessAdmissionPolicy.admitsSnapshotFacts(snapshot))
    }

    @Test("process deltas bind rows, removals, and overview atomically")
    func deltaAuthority() throws {
        let active = makeProcess(
            state: .running,
            visibility: .active,
            sequence: 9
        )
        let overview = SessionProcessOverview(
            revision: 7,
            asOf: "2026-01-01T00:00:09Z",
            activeCount: 1,
            recentCount: 0,
            problemCount: 0,
            visibility: .active
        )
        let valid = SessionProcessDelta(
            activity: active,
            removedProcessIds: ["settled-launcher"],
            processRevision: 7,
            processAsOf: overview.asOf,
            overview: overview
        )
        #expect(SessionProcessAdmissionPolicy.admits(valid))

        let hidden = SessionProcessOverview(
            revision: 7,
            asOf: overview.asOf,
            activeCount: 0,
            recentCount: 0,
            problemCount: 0,
            visibility: .hidden
        )
        #expect(!SessionProcessAdmissionPolicy.admits(SessionProcessDelta(
            activity: active,
            removedProcessIds: nil,
            processRevision: 7,
            processAsOf: hidden.asOf,
            overview: hidden
        )))
        #expect(SessionProcessAdmissionPolicy.admits(SessionProcessDelta(
            activity: nil,
            removedProcessIds: ["settled-launcher"],
            processRevision: 8,
            processAsOf: hidden.asOf,
            overview: SessionProcessOverview(
                revision: 8,
                asOf: hidden.asOf,
                activeCount: 0,
                recentCount: 0,
                problemCount: 0,
                visibility: .hidden
            )
        )))
    }

    @Test("overview count admission cannot overflow")
    func overviewCountBounds() {
        let oversized = SessionProcessOverview(
            revision: 1,
            asOf: "2026-01-01T00:00:00Z",
            activeCount: Int.max,
            recentCount: Int.max,
            problemCount: Int.max,
            visibility: .active
        )
        #expect(!SessionProcessAdmissionPolicy.admits(oversized))
        var snapshot = try? SessionScenarioBuilder(seed: 91_002).openingTail(targetEncodedBytes: 20_000)
        snapshot?.processOverview = oversized
        snapshot?.processActivities = []
        #expect(snapshot.map(SessionProcessAdmissionPolicy.admitsSnapshotFacts) == false)
    }

    @Test("overview problem and expiry facts stay internally consistent")
    func overviewSemanticBounds() {
        #expect(!SessionProcessAdmissionPolicy.admits(SessionProcessOverview(
            revision: 1,
            asOf: "2026-01-01T00:00:00Z",
            activeCount: 1,
            recentCount: 0,
            problemCount: 2,
            visibility: .active
        )))
        #expect(!SessionProcessAdmissionPolicy.admits(SessionProcessOverview(
            revision: 1,
            asOf: "2026-01-01T00:00:00Z",
            activeCount: 1,
            recentCount: 1,
            problemCount: 0,
            visibility: .active
        )))
        #expect(!SessionProcessAdmissionPolicy.admits(SessionProcessOverview(
            revision: 1,
            asOf: "2026-01-01T00:00:00Z",
            activeCount: 1,
            recentCount: 0,
            problemCount: 0,
            visibility: .active,
            nearestExpiry: "2026-01-01T00:05:00Z"
        )))
    }

    @Test("stale recent expiry cannot hide newly active work")
    func staleExpiryCannotHideActive() {
        let active = SessionProcessOverview(
            revision: 2,
            asOf: "2026-01-01T00:00:01Z",
            activeCount: 1,
            recentCount: 0,
            problemCount: 0,
            visibility: .active
        )
        #expect(SessionProcessButtonPolicy.isVisible(
            overview: active,
            hasAdmittedActivity: true,
            localRecentExpired: true
        ))
        let recent = SessionProcessOverview(
            revision: 1,
            asOf: "2026-01-01T00:00:00Z",
            activeCount: 0,
            recentCount: 1,
            problemCount: 0,
            visibility: .recent,
            nearestExpiry: "2026-01-01T00:05:00Z"
        )
        #expect(!SessionProcessButtonPolicy.isVisible(
            overview: recent,
            hasAdmittedActivity: true,
            localRecentExpired: true
        ))
    }

    @Test("every projection retirement path hides through the stable button owner")
    func projectionRetirementVisibility() {
        let recent = SessionProcessOverview(
            revision: 1,
            asOf: "2026-01-01T00:00:00Z",
            activeCount: 0,
            recentCount: 1,
            problemCount: 0,
            visibility: .recent,
            nearestExpiry: "2026-01-01T00:05:00Z"
        )
        let hidden = SessionProcessOverview(
            revision: 2,
            asOf: "2026-01-01T00:05:00Z",
            activeCount: 0,
            recentCount: 0,
            problemCount: 0,
            visibility: .hidden
        )

        #expect(SessionProcessButtonPolicy.isVisible(
            overview: recent,
            hasAdmittedActivity: true,
            localRecentExpired: false
        ))
        #expect(!SessionProcessButtonPolicy.isVisible(
            overview: recent,
            hasAdmittedActivity: false,
            localRecentExpired: false
        ))
        #expect(!SessionProcessButtonPolicy.isVisible(
            overview: hidden,
            hasAdmittedActivity: false,
            localRecentExpired: false
        ))
        #expect(!SessionProcessButtonPolicy.isVisible(
            overview: nil,
            hasAdmittedActivity: false,
            localRecentExpired: false
        ))
        #expect(SessionProcessButtonPolicy.isLocallyExpired(
            recentExpiry: "2026-01-01T00:05:00Z",
            expiredRecentExpiry: "2026-01-01T00:05:00Z"
        ))
        #expect(!SessionProcessButtonPolicy.isLocallyExpired(
            recentExpiry: "2026-01-01T00:10:00Z",
            expiredRecentExpiry: "2026-01-01T00:05:00Z"
        ))
        #expect(!SessionProcessButtonPolicy.isLocallyExpired(
            recentExpiry: nil,
            expiredRecentExpiry: "2026-01-01T00:05:00Z"
        ))
    }

    @Test("visual recent deadline cannot extend server expiry")
    func visualDeadline() {
        let monotonicNow = ContinuousClock.Instant.now
        let wallNow = Date(timeIntervalSince1970: 0)
        let overview = SessionProcessOverview(
            revision: 1, asOf: "1970-01-01T00:00:00Z",
            activeCount: 0, recentCount: 1, problemCount: 0,
            visibility: .recent, nearestExpiry: "1970-01-01T00:00:00.010Z"
        )
        let deadline = SessionProcessVisualDeadline(overview: overview, now: monotonicNow, wallNow: wallNow)
        #expect(!deadline.expired(at: monotonicNow))
        #expect(deadline.expired(at: monotonicNow.advanced(by: .milliseconds(10))))
    }

    private func makeProcess(
        state: SessionProcessLifecycleState = .running,
        visibility: SessionProcessVisibility = .active,
        sequence: Int = 1,
        terminalAt: String? = nil,
        recentUntil: String? = nil,
        currentTool: String? = nil,
        currentPathBasename: String? = nil,
        outputTail: String? = "output"
    ) -> SessionProcessActivity {
        let effectiveRecentUntil = recentUntil ?? (
            terminalAt != nil && (visibility == .recent || visibility == .historical)
                ? "2026-01-01T00:05:01Z"
                : nil
        )
        return SessionProcessActivity(
            processId: "process-\(sequence)-\(state.rawValue)", kind: .subagent,
            executionMode: .asynchronous, source: .delegatedAgent,
            lifecycle: SessionProcessLifecycle(
                state: state, sequence: sequence,
                observedAt: terminalAt ?? "2026-01-01T00:00:02Z",
                terminalAt: terminalAt, recentUntil: effectiveRecentUntil
            ),
            visibility: visibility,
            startedAt: "2026-01-01T00:00:00Z", title: "worker",
            currentTool: currentTool, currentPathBasename: currentPathBasename, outputTail: outputTail,
            toolCallId: "call-1", runId: "run-1"
        )
    }
}
