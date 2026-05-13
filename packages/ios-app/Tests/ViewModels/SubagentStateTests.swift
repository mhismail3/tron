import XCTest
@testable import TronMobile

@MainActor
final class SubagentStateTests: XCTestCase {

    private var sut: SubagentState!

    override func setUp() async throws {
        sut = await SubagentState()
    }

    override func tearDown() async throws {
        sut = nil
    }

    // MARK: - Helper

    private func spawnDefault(
        invocationId: String = "tc-1",
        sessionId: String = "sub-1",
        task: String = "Do something",
        model: String? = "claude-sonnet-4-5",
        blocking: Bool = false
    ) {
        sut.trackSpawn(invocationId: invocationId, subagentSessionId: sessionId, task: task, model: model, blocking: blocking)
    }

    // MARK: - 1A: Mutation + selectedSubagent Sync

    func testTrackSpawn_createsNewSubagent() {
        spawnDefault()
        let data = sut.subagents["sub-1"]
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.invocationId, "tc-1")
        XCTAssertEqual(data?.subagentSessionId, "sub-1")
        XCTAssertEqual(data?.task, "Do something")
        XCTAssertEqual(data?.model, "claude-sonnet-4-5")
        XCTAssertEqual(data?.status, .running)
        XCTAssertEqual(data?.currentTurn, 0)
    }

    func testTrackSpawn_setsBlockingFlag() {
        spawnDefault(blocking: true)
        XCTAssertEqual(sut.subagents["sub-1"]?.blocking, true)

        spawnDefault(invocationId: "tc-2", sessionId: "sub-2", blocking: false)
        XCTAssertEqual(sut.subagents["sub-2"]?.blocking, false)
    }

    func testUpdateStatus_updatesSubagentData() {
        spawnDefault()
        sut.updateStatus(subagentSessionId: "sub-1", status: .running, currentTurn: 3)

        let data = sut.subagents["sub-1"]
        XCTAssertEqual(data?.status, .running)
        XCTAssertEqual(data?.currentTurn, 3)
    }

    func testUpdateStatus_syncsSelectedSubagent_whenMatching() {
        spawnDefault()
        sut.showDetails(for: "sub-1")
        XCTAssertEqual(sut.selectedSubagent?.currentTurn, 0)

        sut.updateStatus(subagentSessionId: "sub-1", status: .running, currentTurn: 5)
        XCTAssertEqual(sut.selectedSubagent?.currentTurn, 5)
    }

    func testUpdateStatus_doesNotSyncSelectedSubagent_whenDifferent() {
        spawnDefault()
        spawnDefault(invocationId: "tc-2", sessionId: "sub-2")
        sut.showDetails(for: "sub-2")

        sut.updateStatus(subagentSessionId: "sub-1", status: .running, currentTurn: 10)
        XCTAssertEqual(sut.selectedSubagent?.subagentSessionId, "sub-2")
        XCTAssertEqual(sut.selectedSubagent?.currentTurn, 0)
    }

    func testUpdateStatus_ignoresUnknownSessionId() {
        sut.updateStatus(subagentSessionId: "unknown", status: .running, currentTurn: 1)
        XCTAssertTrue(sut.subagents.isEmpty)
    }

    func testComplete_setsAllFields() {
        spawnDefault()
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: nil, cacheCreationTokens: nil)
        sut.complete(
            subagentSessionId: "sub-1",
            resultSummary: "Done",
            fullOutput: "Full output text",
            totalTurns: 5,
            duration: 1234,
            tokenUsage: usage,
            model: "claude-opus-4-6"
        )

        let data = sut.subagents["sub-1"]
        XCTAssertEqual(data?.status, .completed)
        XCTAssertEqual(data?.resultSummary, "Done")
        XCTAssertEqual(data?.fullOutput, "Full output text")
        XCTAssertEqual(data?.currentTurn, 5)
        XCTAssertEqual(data?.duration, 1234)
        XCTAssertEqual(data?.tokenUsage?.inputTokens, 100)
        XCTAssertEqual(data?.model, "claude-opus-4-6")
    }

    func testComplete_updatesModel_whenProvided() {
        spawnDefault(model: "old-model")
        sut.complete(subagentSessionId: "sub-1", resultSummary: "OK", fullOutput: nil, totalTurns: 1, duration: 100, tokenUsage: nil, model: "new-model")
        XCTAssertEqual(sut.subagents["sub-1"]?.model, "new-model")
    }

    func testComplete_preservesExistingModel_whenNotProvided() {
        spawnDefault(model: "original-model")
        sut.complete(subagentSessionId: "sub-1", resultSummary: "OK", fullOutput: nil, totalTurns: 1, duration: 100, tokenUsage: nil)
        XCTAssertEqual(sut.subagents["sub-1"]?.model, "original-model")
    }

    func testComplete_syncsSelectedSubagent() {
        spawnDefault()
        sut.showDetails(for: "sub-1")
        sut.complete(subagentSessionId: "sub-1", resultSummary: "Done", fullOutput: nil, totalTurns: 3, duration: 500, tokenUsage: nil)
        XCTAssertEqual(sut.selectedSubagent?.status, .completed)
        XCTAssertEqual(sut.selectedSubagent?.resultSummary, "Done")
    }

    func testFail_setsErrorAndDuration() {
        spawnDefault()
        sut.fail(subagentSessionId: "sub-1", error: "Boom", duration: 999)

        let data = sut.subagents["sub-1"]
        XCTAssertEqual(data?.status, .failed)
        XCTAssertEqual(data?.error, "Boom")
        XCTAssertEqual(data?.duration, 999)
    }

    func testFail_syncsSelectedSubagent() {
        spawnDefault()
        sut.showDetails(for: "sub-1")
        sut.fail(subagentSessionId: "sub-1", error: "Oops", duration: 100)
        XCTAssertEqual(sut.selectedSubagent?.status, .failed)
        XCTAssertEqual(sut.selectedSubagent?.error, "Oops")
    }

    func testMarkResultsPending_setsStatus() {
        spawnDefault()
        sut.markResultsPending(subagentSessionId: "sub-1")
        XCTAssertEqual(sut.subagents["sub-1"]?.resultDeliveryStatus, .pending)
    }

    func testMarkResultsSent_setsStatus() {
        spawnDefault()
        sut.markResultsSent(subagentSessionId: "sub-1")
        XCTAssertEqual(sut.subagents["sub-1"]?.resultDeliveryStatus, .sent)
    }

    func testMarkResultsDismissed_setsStatus() {
        spawnDefault()
        sut.markResultsDismissed(subagentSessionId: "sub-1")
        XCTAssertEqual(sut.subagents["sub-1"]?.resultDeliveryStatus, .dismissed)
    }

    func testAllMarkMethods_syncSelectedSubagent() {
        for (method, expected): ((String) -> Void, SubagentResultDeliveryStatus) in [
            (sut.markResultsPending, .pending),
            (sut.markResultsSent, .sent),
            (sut.markResultsDismissed, .dismissed)
        ] {
            sut.clearAll()
            spawnDefault()
            sut.showDetails(for: "sub-1")
            method("sub-1")
            XCTAssertEqual(sut.selectedSubagent?.resultDeliveryStatus, expected,
                           "Expected \(expected) after marking")
        }
    }

    func testClearAll_removesEverything() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "hello"]), timestamp: "2026-01-01T00:00:00Z")
        sut.showDetails(for: "sub-1")

        sut.clearAll()
        XCTAssertTrue(sut.subagents.isEmpty)
        XCTAssertTrue(sut.subagentEvents.isEmpty)
        XCTAssertNil(sut.selectedSubagent)
        XCTAssertFalse(sut.showDetailSheet)
    }

    // MARK: - 1B: Capability-Native Forwarded Events

    func testAddForwardedEvent_capabilityStarted() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "capability.invocation.started", eventData: AnyCodable(["modelToolName": "bash", "invocationId": "t1"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .capabilityInvocation)
    }

    func testAddForwardedEvent_retiredToolStartFormat_isIgnored() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool" + "_start", eventData: AnyCodable(["modelToolName": "read", "invocationId": "t2"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertTrue(events.isEmpty)
    }

    func testAddForwardedEvent_retiredToolDotFormat_isIgnored() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool" + ".call", eventData: AnyCodable(["modelToolName": "edit", "invocationId": "t3"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertTrue(events.isEmpty)
    }

    func testAddForwardedEvent_capabilityCompleted() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "capability.invocation.completed", eventData: AnyCodable(["success": true, "invocationId": "t1"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
    }

    func testAddForwardedEvent_textDelta() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "hello"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .output)
    }

    func testAddForwardedEvent_thinkingDelta() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.thinking_delta", eventData: AnyCodable(["delta": "hmm"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .thinking)
    }

    func testAddForwardedEvent_unknownType_isIgnored() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "session.start", eventData: AnyCodable([:]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertTrue(events.isEmpty)
    }

    func testAddForwardedEvent_emptyDelta_isIgnored() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": ""]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertTrue(events.isEmpty)
    }

    func testAddForwardedEvent_capabilityStartedThenCompleted_mergesEvents() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "capability.invocation.started", eventData: AnyCodable(["modelToolName": "bash", "invocationId": "tc-100"]), timestamp: "2026-01-01T00:00:00Z")
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "capability.invocation.completed", eventData: AnyCodable(["success": true, "invocationId": "tc-100", "result": "output"]), timestamp: "2026-01-01T00:00:01Z")

        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1, "capability completion should merge into started event, not add a new event")
        XCTAssertFalse(events.first?.isRunning ?? true)
    }

    func testAddForwardedEvent_capabilityCompletedWithoutStart_createsStandaloneEvent() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "capability.invocation.completed", eventData: AnyCodable(["success": false, "invocationId": "orphan"]), timestamp: "2026-01-01T00:00:00Z")

        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events.first?.isRunning ?? true)
    }

    func testAddForwardedEvent_textDelta_appendsToExistingOutput() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "Hello "]), timestamp: "2026-01-01T00:00:00Z")
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "World"]), timestamp: "2026-01-01T00:00:01Z")

        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1, "Consecutive text deltas should merge into single output event")
    }

    func testAddForwardedEvent_textDelta_afterTool_createsNewOutputBlock() {
        spawnDefault()
        // First output block
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "First"]), timestamp: "2026-01-01T00:00:00Z")
        // Tool interrupts
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "capability.invocation.started", eventData: AnyCodable(["modelToolName": "bash", "invocationId": "t1"]), timestamp: "2026-01-01T00:00:01Z")
        // Second output block after tool
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "Second"]), timestamp: "2026-01-01T00:00:02Z")

        let events = sut.getEvents(for: "sub-1")
        let outputEvents = events.filter { $0.type == .output }
        XCTAssertEqual(outputEvents.count, 2, "Text after tool should create a new output block")
    }

    func testAddForwardedEvent_thinkingDelta_onlyAddsOnce() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.thinking_delta", eventData: AnyCodable(["delta": "hmm"]), timestamp: "2026-01-01T00:00:00Z")
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.thinking_delta", eventData: AnyCodable(["delta": "more thinking"]), timestamp: "2026-01-01T00:00:01Z")

        let events = sut.getEvents(for: "sub-1")
        let thinkingEvents = events.filter { $0.type == .thinking }
        XCTAssertEqual(thinkingEvents.count, 1, "Multiple thinking deltas should only create one thinking indicator")
    }

    func testAddForwardedEvent_capabilityStart_finalizesRunningOutputEvents() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "Running text"]), timestamp: "2026-01-01T00:00:00Z")

        // Verify output is running
        let beforeEvents = sut.subagentEvents["sub-1"] ?? []
        XCTAssertTrue(beforeEvents.last?.isRunning ?? false)

        // Capability start should finalize running output
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "capability.invocation.started", eventData: AnyCodable(["modelToolName": "bash", "invocationId": "t1"]), timestamp: "2026-01-01T00:00:01Z")

        let afterEvents = sut.subagentEvents["sub-1"] ?? []
        let outputEvent = afterEvents.first(where: { $0.type == .output })
        XCTAssertFalse(outputEvent?.isRunning ?? true, "capability.invocation.started should finalize running output events")
    }

    // MARK: - 1C: ISO8601 Formatter Caching

    func testAddForwardedEvent_parsesTimestamp() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "test"]), timestamp: "2026-06-15T10:30:00Z")

        let events = sut.subagentEvents["sub-1"] ?? []
        XCTAssertNotNil(events.first?.timestamp)
    }

    func testAddForwardedEvent_invalidTimestamp_fallsToCurrentDate() {
        spawnDefault()
        let before = Date()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.text_delta", eventData: AnyCodable(["delta": "test"]), timestamp: "not-a-date")
        let after = Date()

        let events = sut.subagentEvents["sub-1"] ?? []
        if let eventDate = events.first?.timestamp {
            XCTAssertGreaterThanOrEqual(eventDate, before)
            XCTAssertLessThanOrEqual(eventDate, after)
        }
    }

    // MARK: - 1D: Query/Helper Tests

    func testGetSubagentByInvocationId_returnsCorrectSubagent() {
        spawnDefault(invocationId: "tc-1", sessionId: "sub-1")
        spawnDefault(invocationId: "tc-2", sessionId: "sub-2")

        let result = sut.getSubagentByInvocationId("tc-2")
        XCTAssertEqual(result?.subagentSessionId, "sub-2")
    }

    func testGetSubagentByInvocationId_returnsNil_whenNotFound() {
        spawnDefault()
        XCTAssertNil(sut.getSubagentByInvocationId("nonexistent"))
    }

    func testHasRunningSubagents_true_whenRunning() {
        spawnDefault()
        XCTAssertTrue(sut.hasRunningSubagents)
    }

    func testHasRunningSubagents_false_whenAllComplete() {
        spawnDefault()
        sut.complete(subagentSessionId: "sub-1", resultSummary: "Done", fullOutput: nil, totalTurns: 1, duration: 100, tokenUsage: nil)
        XCTAssertFalse(sut.hasRunningSubagents)
    }

    func testShowDetails_setsSelectedAndShowsSheet() {
        spawnDefault()
        sut.showDetails(for: "sub-1")
        XCTAssertEqual(sut.selectedSubagent?.subagentSessionId, "sub-1")
        XCTAssertTrue(sut.showDetailSheet)
    }

    func testShowDetails_unknownId_doesNothing() {
        sut.showDetails(for: "unknown")
        XCTAssertNil(sut.selectedSubagent)
        XCTAssertFalse(sut.showDetailSheet)
    }

    func testShowDetailsWithData_addsToTrackedIfNew() {
        let data = SubagentToolData(
            invocationId: "tc-ext",
            subagentSessionId: "sub-ext",
            task: "External task",
            model: nil,
            status: .completed,
            currentTurn: 2,
            resultSummary: "OK",
            fullOutput: nil,
            duration: 500,
            error: nil,
            tokenUsage: nil
        )
        sut.showDetails(with: data)
        XCTAssertNotNil(sut.subagents["sub-ext"])
        XCTAssertEqual(sut.selectedSubagent?.subagentSessionId, "sub-ext")
        XCTAssertTrue(sut.showDetailSheet)
    }

    func testDismissDetails_hidesSheet_keepsSelectedForAnimation() {
        spawnDefault()
        sut.showDetails(for: "sub-1")
        XCTAssertTrue(sut.showDetailSheet)

        sut.dismissDetails()
        XCTAssertFalse(sut.showDetailSheet)
        XCTAssertNotNil(sut.selectedSubagent, "selectedSubagent should be kept for dismissal animation")
    }

    func testGetEvents_returnsReversed() {
        spawnDefault()
        sut.addForwardedEvent(
            subagentSessionId: "sub-1",
            eventType: "capability.invocation.started",
            eventData: AnyCodable(["modelToolName": "execute", "contractId": "process::run", "invocationId": "t1"]),
            timestamp: "2026-01-01T00:00:00Z"
        )
        sut.addForwardedEvent(
            subagentSessionId: "sub-1",
            eventType: "capability.invocation.started",
            eventData: AnyCodable(["modelToolName": "execute", "contractId": "filesystem::read_file", "invocationId": "t2"]),
            timestamp: "2026-01-01T00:00:01Z"
        )

        let events = sut.getEvents(for: "sub-1")
        // Reversed = newest first, so the read-file capability should be first.
        XCTAssertEqual(events.first?.invocationId, "t2")
        XCTAssertTrue(events.first?.title.contains("Read File") ?? false)
    }

    func testPopulateFromReconstruction_addsSubagent() {
        let data = SubagentToolData(
            invocationId: "tc-r",
            subagentSessionId: "sub-r",
            task: "Reconstructed",
            model: "claude-haiku-3",
            status: .completed,
            currentTurn: 1,
            resultSummary: "OK",
            fullOutput: nil,
            duration: 200,
            error: nil,
            tokenUsage: nil
        )
        sut.populateFromReconstruction(data)
        XCTAssertNotNil(sut.subagents["sub-r"])
        XCTAssertEqual(sut.subagents["sub-r"]?.task, "Reconstructed")
    }

    // MARK: - Spawn Type Filtering

    func testTrackSpawn_defaultSpawnType_isToolAgent() {
        spawnDefault()
        XCTAssertEqual(sut.subagents["sub-1"]?.spawnType, .toolAgent)
    }

    func testTrackSpawn_withHookSpawnType() {
        sut.trackSpawn(
            invocationId: "hook-1", subagentSessionId: "sub-hook",
            task: "Generate title", model: nil, spawnType: .hook
        )
        XCTAssertEqual(sut.subagents["sub-hook"]?.spawnType, .hook)
    }

    func testHasRunningSubagents_trueForToolAgent() {
        spawnDefault()  // default is .toolAgent
        XCTAssertTrue(sut.hasRunningSubagents)
    }

    func testHasRunningSubagents_falseForHookOnly() {
        sut.trackSpawn(
            invocationId: "hook-1", subagentSessionId: "sub-hook",
            task: "Generate title", model: nil, spawnType: .hook
        )
        XCTAssertFalse(sut.hasRunningSubagents,
            "Hook-only subagents should not count as running subagents")
    }

    func testHasRunningSubagents_mixedTypes_hookAndCompletedTool() {
        // Running hook + completed tool → false
        sut.trackSpawn(
            invocationId: "hook-1", subagentSessionId: "sub-hook",
            task: "Generate title", model: nil, spawnType: .hook
        )
        spawnDefault()
        sut.complete(
            subagentSessionId: "sub-1", resultSummary: "Done",
            fullOutput: nil, totalTurns: 1, duration: 100, tokenUsage: nil, model: nil
        )
        XCTAssertFalse(sut.hasRunningSubagents)
    }

    func testHasRunningSubagents_mixedTypes_toolRunning() {
        // Running tool + running hook → true (tool counts)
        sut.trackSpawn(
            invocationId: "hook-1", subagentSessionId: "sub-hook",
            task: "Generate title", model: nil, spawnType: .hook
        )
        spawnDefault()
        XCTAssertTrue(sut.hasRunningSubagents)
    }

    func testComplete_hookSubagent_doesNotAffectHasRunning() {
        sut.trackSpawn(
            invocationId: "hook-1", subagentSessionId: "sub-hook",
            task: "Generate title", model: nil, spawnType: .hook
        )
        XCTAssertFalse(sut.hasRunningSubagents)
        sut.complete(
            subagentSessionId: "sub-hook", resultSummary: "Title",
            fullOutput: nil, totalTurns: 1, duration: 200, tokenUsage: nil, model: nil
        )
        XCTAssertFalse(sut.hasRunningSubagents)
    }

    // MARK: - Event Limit

    func testAddForwardedEvent_enforcesMaxEventsPerSubagent() {
        spawnDefault()
        // Add 510 events (exceeds 500 limit)
        for i in 0..<510 {
            sut.addForwardedEvent(
                subagentSessionId: "sub-1",
                eventType: "capability.invocation.started",
                eventData: AnyCodable(["modelToolName": "bash", "invocationId": "t\(i)"]),
                timestamp: "2026-01-01T00:00:00Z"
            )
        }

        let events = sut.subagentEvents["sub-1"] ?? []
        XCTAssertLessThanOrEqual(events.count, 500, "Events should be capped at maxEventsPerSubagent")
    }

}
