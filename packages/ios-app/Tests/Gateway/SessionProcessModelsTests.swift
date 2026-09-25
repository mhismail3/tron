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

    @Test("history timestamps use terminal time only, never start or observation time")
    func historyCompletedTimestamp() throws {
        let now = try #require(GatewayTimestamp.parse("2026-01-01T14:00:00Z"))
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let process = makeProcess(state: .completed, terminalAt: "2026-01-01T13:45:00Z")
        let text = try #require(SessionProcessRowPresentation.completedText(for: process, relativeTo: now,
            locale: Locale(identifier: "en_US_POSIX"), timeZone: zone))
        #expect(text.hasPrefix("1:45"))
        #expect(text.contains("PM"))
        #expect(SessionProcessRowPresentation.completedText(for: makeProcess(state: .completed)) == nil)
        #expect(SessionProcessRowPresentation.completedText(for: makeProcess(state: .running, terminalAt: "2026-01-01T13:45:00Z")) == nil)
        #expect(SessionProcessRowPresentation.completedText(for: makeProcess(state: .completed, terminalAt: "malformed")) == nil)
    }

    @Test("running counters advance from receipt uptime without comparing Mac and iPhone clocks")
    func liveElapsedCounter() throws {
        let now = try #require(GatewayTimestamp.parse("2026-01-01T00:00:10Z"))
        let process = makeProcess(startedAt: "2030-01-01T00:00:00Z", durationMs: 4_200, sampleUptime: 100)
        #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: process, at: now, uptime: 100) == 4_200)
        #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: process, at: now, uptime: 103) == 7_200)
        #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: process, at: now.addingTimeInterval(-3_600), uptime: 104) == 8_200)
        #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: makeProcess(), at: now) == 10_000)
        #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: makeProcess(startedAt: nil), at: now) == nil)
        for state: SessionProcessLifecycleState in [.queued, .paused, .completed, .failed, .stopped] {
            let frozen = makeProcess(state: state, durationMs: 4_200, sampleUptime: 100)
            #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: frozen, at: now, uptime: 9_000) == 4_200)
        }
        let completed = makeProcess(state: .completed, terminalAt: "2026-01-01T00:00:09Z")
        #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: completed, at: now.addingTimeInterval(3_600)) == 9_000)
        #expect(SessionProcessRowPresentation.durationText(3_661_000) == "1h 1m 1s")
        #expect(SessionProcessRowPresentation.durationText(3_662_000) == "1h 1m 2s")
    }

    @Test("progress publications and row remounts retain the exact duration sample anchor")
    func durationSampleProjection() throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_061).openingTail(targetEncodedBytes: 4_096)
        snapshot.processActivities = [makeProcess(durationMs: 1_000, sampleUptime: 100)]
        let initial = SessionProcessPresentation(snapshot)
        snapshot.processActivities = [makeProcess(outputTail: "new progress", durationMs: 1_000, sampleUptime: 110)]
        let updated = SessionProcessPresentation(snapshot, previous: initial)
        let current = try #require(updated.activities.first)
        #expect(current.durationSampleAnchor.uptime == 100)
        #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: current, uptime: 112) == 13_000)

        snapshot.processActivities = [makeProcess(durationMs: 14_000, sampleUptime: 113)]
        let next = try #require(SessionProcessPresentation(snapshot, previous: updated).activities.first)
        #expect(next.durationSampleAnchor.uptime == 113)
        #expect(SessionProcessRowPresentation.elapsedMilliseconds(for: next, uptime: 114) == 15_000)

        let encoded = try JSONEncoder().encode(current)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["durationSampleAnchor"] == nil)
        let decoded = try JSONDecoder.gateway.decode(SessionProcessActivity.self, from: encoded)
        #expect(decoded == current)
        #expect(decoded.durationSampleAnchor.uptime != 100)
    }

    @Test("subagent rows standardize the latest action and bound output to three lines")
    func rowPresentation() {
        let process = makeProcess(
            currentTool: "bash",
            currentPathBasename: "worktree.log",
            outputTail: "one\ntwo\nthree\nfour\nfive"
        )
        #expect(SessionProcessRowPresentation.latestAction(for: process) == "bash · worktree.log")
        let preview = SessionProcessRowPresentation.outputPreview(process.outputTail)
        #expect(preview?.text == "three\nfour\nfive")
        #expect(preview?.isBounded == true)
        #expect(preview?.renderedLineCount == 3)
        #expect(SessionProcessRowPresentation.outputPreview("one\r\ntwo\r\nthree\r\n")?.text == "one\ntwo\nthree")
        #expect(SessionProcessRowPresentation.outputPreview("one\ntwo\nthree")?.isBounded == false)
        #expect(SessionProcessRowPresentation.outputPreview(String(repeating: "👋", count: 300))?.text.count == 180)
        #expect(SessionProcessRowPresentation.outputPreview(" \n\n") == nil)
        #expect(SessionProcessRowPresentation.outputPreview(nil) == nil)
        #expect(SessionProcessRowPresentation.latestAction(for: makeProcess(
            currentTool: "bash",
            currentPathBasename: "null"
        )) == "bash")
        #expect(SessionProcessRowPresentation.countLabel(1, singular: "tool") == "1 tool")
        #expect(SessionProcessRowPresentation.countLabel(2, singular: "turn") == "2 turns")
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

    @Test("active subagent order is stable across progress timestamps")
    func activeOrderUsesStartBoundary() {
        let first = makeProcess(
            sequence: 1,
            observedAt: "2026-01-01T00:00:20Z",
            startedAt: "2026-01-01T00:00:01Z"
        )
        let second = makeProcess(
            sequence: 2,
            observedAt: "2026-01-01T00:00:10Z",
            startedAt: "2026-01-01T00:00:02Z"
        )
        #expect(SessionProcessProjection.sections([first, second]).active.map(\.processId) == [second.processId, first.processId])

        let firstHeartbeat = makeProcess(
            sequence: 1,
            observedAt: "2026-01-01T00:00:30Z",
            startedAt: "2026-01-01T00:00:01Z"
        )
        #expect(SessionProcessProjection.sections([firstHeartbeat, second]).active.map(\.processId) == [second.processId, first.processId])
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

    @Test("app retention uses terminal timestamps without changing Gateway expiry")
    func appRetentionWindow() {
        let overview = SessionProcessOverview(
            revision: 1, asOf: "2026-01-01T00:00:00Z",
            activeCount: 0, recentCount: 1, problemCount: 0,
            visibility: .recent, nearestExpiry: "2026-01-01T00:05:00Z"
        )
        let activity = makeProcess(
            state: .completed,
            visibility: .recent,
            terminalAt: "2026-01-01T00:00:00Z",
            recentUntil: "2026-01-01T00:05:00Z"
        )
        #expect(SessionProcessButtonPolicy.preferredRecentExpiry(
            overview: overview, activities: [activity], retentionMinutes: 5
        ) == "2026-01-01T00:05:00.000Z")
        #expect(SessionProcessButtonPolicy.preferredRecentExpiry(
            overview: overview, activities: [activity], retentionMinutes: 1
        ) == "2026-01-01T00:01:00.000Z")
        #expect(SessionProcessButtonPolicy.preferredRecentExpiry(
            overview: overview, activities: [activity], retentionMinutes: 0
        ) == nil)
        #expect(SessionProcessButtonPolicy.isVisible(
            overview: overview, hasAdmittedActivity: true, localRecentExpired: false,
            recentFinishedRetentionMinutes: 0
        ) == false)
        #expect(SessionProcessButtonPolicy.isVisible(
            overview: overview, hasAdmittedActivity: true, localRecentExpired: true,
            recentFinishedRetentionMinutes: 5
        ) == false)
    }

    @Test("the last eligible completion owns orb expiry and zero keeps only active rows")
    func staggeredAppRetention() throws {
        let overview = SessionProcessOverview(
            revision: 1, asOf: "2026-01-01T00:00:00Z",
            activeCount: 0, recentCount: 2, problemCount: 0,
            visibility: .recent, nearestExpiry: "2026-01-01T00:05:00Z"
        )
        let older = makeProcess(state: .completed, visibility: .recent,
                                terminalAt: "2026-01-01T00:00:00Z", recentUntil: "2026-01-01T00:05:00Z")
        let newer = makeProcess(state: .completed, visibility: .recent,
                                terminalAt: "2026-01-01T00:01:00Z", recentUntil: "2026-01-01T00:06:00Z")
        let now = try #require(GatewayTimestamp.parse("2026-01-01T00:01:30Z"))
        #expect(SessionProcessButtonPolicy.preferredRecentExpiry(
            overview: overview, activities: [older, newer], retentionMinutes: 1
        ) == "2026-01-01T00:02:00.000Z")
        #expect(SessionProcessButtonPolicy.preferredRecentExpiry(
            overview: overview, activities: [older, newer], retentionMinutes: 5
        ) == "2026-01-01T00:06:00.000Z")
        #expect(SessionProcessButtonPolicy.visibleActivities(
            [older, newer], retentionMinutes: 1, now: now
        ) == [newer])
        let active = makeProcess()
        #expect(SessionProcessButtonPolicy.visibleActivities(
            [older, newer, active], retentionMinutes: 0, now: now
        ) == [active])
        #expect(SessionProcessButtonPolicy.visibleActivities(
            [newer], retentionMinutes: 1, now: now.addingTimeInterval(30)
        ).isEmpty)
        #expect(SessionProcessButtonPolicy.isLocallyExpired(
            recentExpiry: "2026-01-01T00:01:00Z", expiredRecentExpiry: nil, now: now
        ), "Mounting after expiry must not briefly reveal the orb before its timer runs")
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
        observedAt: String? = nil,
        startedAt: String? = "2026-01-01T00:00:00Z",
        currentTool: String? = nil,
        currentPathBasename: String? = nil,
        outputTail: String? = "output",
        durationMs: Int? = nil,
        sampleUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
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
                observedAt: observedAt ?? terminalAt ?? "2026-01-01T00:00:02Z",
                terminalAt: terminalAt, recentUntil: effectiveRecentUntil
            ),
            visibility: visibility,
            startedAt: startedAt, title: "worker",
            currentTool: currentTool, currentPathBasename: currentPathBasename, outputTail: outputTail,
            durationMs: durationMs, toolCallId: "call-1", runId: "run-1",
            durationSampleAnchor: ToolDurationSampleAnchor(uptime: sampleUptime)
        )
    }
}
