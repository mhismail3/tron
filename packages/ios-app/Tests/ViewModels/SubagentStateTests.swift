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
        toolCallId: String = "tc-1",
        sessionId: String = "sub-1",
        task: String = "Do something",
        model: String? = "claude-sonnet-4-5",
        blocking: Bool = false
    ) {
        sut.trackSpawn(toolCallId: toolCallId, subagentSessionId: sessionId, task: task, model: model, blocking: blocking)
    }

    // MARK: - 1A: Mutation + selectedSubagent Sync

    func testTrackSpawn_createsNewSubagent() {
        spawnDefault()
        let data = sut.subagents["sub-1"]
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.toolCallId, "tc-1")
        XCTAssertEqual(data?.subagentSessionId, "sub-1")
        XCTAssertEqual(data?.task, "Do something")
        XCTAssertEqual(data?.model, "claude-sonnet-4-5")
        XCTAssertEqual(data?.status, .running)
        XCTAssertEqual(data?.currentTurn, 0)
    }

    func testTrackSpawn_setsBlockingFlag() {
        spawnDefault(blocking: true)
        XCTAssertEqual(sut.subagents["sub-1"]?.blocking, true)

        spawnDefault(toolCallId: "tc-2", sessionId: "sub-2", blocking: false)
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
        spawnDefault(toolCallId: "tc-2", sessionId: "sub-2")
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
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": "hello"]), timestamp: "2026-01-01T00:00:00Z")
        sut.showDetails(for: "sub-1")

        sut.clearAll()
        XCTAssertTrue(sut.subagents.isEmpty)
        XCTAssertTrue(sut.subagentEvents.isEmpty)
        XCTAssertNil(sut.selectedSubagent)
        XCTAssertFalse(sut.showDetailSheet)
    }

    // MARK: - 1B: Event Type Normalization

    func testAddForwardedEvent_toolStart_dotFormat() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool.start", eventData: AnyCodable(["toolName": "bash", "toolCallId": "t1"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .tool)
    }

    func testAddForwardedEvent_toolStart_underscoreFormat() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool_start", eventData: AnyCodable(["toolName": "read", "toolCallId": "t2"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .tool)
    }

    func testAddForwardedEvent_toolStart_agentPrefixFormat() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "agent.tool_start", eventData: AnyCodable(["toolName": "edit", "toolCallId": "t3"]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .tool)
    }

    func testAddForwardedEvent_toolEnd_allFormats() {
        for eventType in ["tool_end", "tool.end", "agent.tool_end"] {
            sut.clearAll()
            spawnDefault()
            sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: eventType, eventData: AnyCodable(["success": true, "toolCallId": "t1"]), timestamp: "2026-01-01T00:00:00Z")
            let events = sut.getEvents(for: "sub-1")
            XCTAssertEqual(events.count, 1, "Failed for eventType: \(eventType)")
        }
    }

    func testAddForwardedEvent_textDelta_allFormats() {
        for eventType in ["text_delta", "text.delta", "agent.text_delta"] {
            sut.clearAll()
            spawnDefault()
            sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: eventType, eventData: AnyCodable(["delta": "hello"]), timestamp: "2026-01-01T00:00:00Z")
            let events = sut.getEvents(for: "sub-1")
            XCTAssertEqual(events.count, 1, "Failed for eventType: \(eventType)")
            XCTAssertEqual(events.first?.type, .output)
        }
    }

    func testAddForwardedEvent_thinkingDelta_allFormats() {
        for eventType in ["thinking_delta", "thinking.delta", "agent.thinking_delta"] {
            sut.clearAll()
            spawnDefault()
            sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: eventType, eventData: AnyCodable(["delta": "hmm"]), timestamp: "2026-01-01T00:00:00Z")
            let events = sut.getEvents(for: "sub-1")
            XCTAssertEqual(events.count, 1, "Failed for eventType: \(eventType)")
            XCTAssertEqual(events.first?.type, .thinking)
        }
    }

    func testAddForwardedEvent_unknownType_isIgnored() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "session.start", eventData: AnyCodable([:]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertTrue(events.isEmpty)
    }

    func testAddForwardedEvent_emptyDelta_isIgnored() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": ""]), timestamp: "2026-01-01T00:00:00Z")
        let events = sut.getEvents(for: "sub-1")
        XCTAssertTrue(events.isEmpty)
    }

    func testAddForwardedEvent_toolStartThenEnd_mergesEvents() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool_start", eventData: AnyCodable(["toolName": "bash", "toolCallId": "tc-100"]), timestamp: "2026-01-01T00:00:00Z")
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool_end", eventData: AnyCodable(["success": true, "toolCallId": "tc-100", "result": "output"]), timestamp: "2026-01-01T00:00:01Z")

        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1, "tool_end should merge into tool_start, not add a new event")
        XCTAssertFalse(events.first?.isRunning ?? true)
    }

    func testAddForwardedEvent_toolEndWithoutStart_createsStandaloneEvent() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool_end", eventData: AnyCodable(["success": false, "toolCallId": "orphan"]), timestamp: "2026-01-01T00:00:00Z")

        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events.first?.isRunning ?? true)
    }

    func testAddForwardedEvent_textDelta_appendsToExistingOutput() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": "Hello "]), timestamp: "2026-01-01T00:00:00Z")
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": "World"]), timestamp: "2026-01-01T00:00:01Z")

        let events = sut.getEvents(for: "sub-1")
        XCTAssertEqual(events.count, 1, "Consecutive text deltas should merge into single output event")
    }

    func testAddForwardedEvent_textDelta_afterTool_createsNewOutputBlock() {
        spawnDefault()
        // First output block
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": "First"]), timestamp: "2026-01-01T00:00:00Z")
        // Tool interrupts
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool_start", eventData: AnyCodable(["toolName": "bash", "toolCallId": "t1"]), timestamp: "2026-01-01T00:00:01Z")
        // Second output block after tool
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": "Second"]), timestamp: "2026-01-01T00:00:02Z")

        let events = sut.getEvents(for: "sub-1")
        let outputEvents = events.filter { $0.type == .output }
        XCTAssertEqual(outputEvents.count, 2, "Text after tool should create a new output block")
    }

    func testAddForwardedEvent_thinkingDelta_onlyAddsOnce() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "thinking_delta", eventData: AnyCodable(["delta": "hmm"]), timestamp: "2026-01-01T00:00:00Z")
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "thinking_delta", eventData: AnyCodable(["delta": "more thinking"]), timestamp: "2026-01-01T00:00:01Z")

        let events = sut.getEvents(for: "sub-1")
        let thinkingEvents = events.filter { $0.type == .thinking }
        XCTAssertEqual(thinkingEvents.count, 1, "Multiple thinking deltas should only create one thinking indicator")
    }

    func testAddForwardedEvent_toolStart_finalizesRunningOutputEvents() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": "Running text"]), timestamp: "2026-01-01T00:00:00Z")

        // Verify output is running
        let beforeEvents = sut.subagentEvents["sub-1"] ?? []
        XCTAssertTrue(beforeEvents.last?.isRunning ?? false)

        // Tool start should finalize running output
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool_start", eventData: AnyCodable(["toolName": "bash", "toolCallId": "t1"]), timestamp: "2026-01-01T00:00:01Z")

        let afterEvents = sut.subagentEvents["sub-1"] ?? []
        let outputEvent = afterEvents.first(where: { $0.type == .output })
        XCTAssertFalse(outputEvent?.isRunning ?? true, "tool_start should finalize running output events")
    }

    // MARK: - 1C: ISO8601 Formatter Caching

    func testAddForwardedEvent_parsesTimestamp() {
        spawnDefault()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": "test"]), timestamp: "2026-06-15T10:30:00Z")

        let events = sut.subagentEvents["sub-1"] ?? []
        XCTAssertNotNil(events.first?.timestamp)
    }

    func testAddForwardedEvent_invalidTimestamp_fallsToCurrentDate() {
        spawnDefault()
        let before = Date()
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "text_delta", eventData: AnyCodable(["delta": "test"]), timestamp: "not-a-date")
        let after = Date()

        let events = sut.subagentEvents["sub-1"] ?? []
        if let eventDate = events.first?.timestamp {
            XCTAssertGreaterThanOrEqual(eventDate, before)
            XCTAssertLessThanOrEqual(eventDate, after)
        }
    }

    // MARK: - 1D: Query/Helper Tests

    func testGetSubagentByToolCallId_returnsCorrectSubagent() {
        spawnDefault(toolCallId: "tc-1", sessionId: "sub-1")
        spawnDefault(toolCallId: "tc-2", sessionId: "sub-2")

        let result = sut.getSubagentByToolCallId("tc-2")
        XCTAssertEqual(result?.subagentSessionId, "sub-2")
    }

    func testGetSubagentByToolCallId_returnsNil_whenNotFound() {
        spawnDefault()
        XCTAssertNil(sut.getSubagentByToolCallId("nonexistent"))
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
            toolCallId: "tc-ext",
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
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool_start", eventData: AnyCodable(["toolName": "bash", "toolCallId": "t1"]), timestamp: "2026-01-01T00:00:00Z")
        sut.addForwardedEvent(subagentSessionId: "sub-1", eventType: "tool_start", eventData: AnyCodable(["toolName": "read", "toolCallId": "t2"]), timestamp: "2026-01-01T00:00:01Z")

        let events = sut.getEvents(for: "sub-1")
        // Reversed = newest first, so "read" should be first
        XCTAssertTrue(events.first?.title.contains("Read") ?? false,
                       "Events should be in reverse order (newest first)")
    }

    func testPopulateFromReconstruction_addsSubagent() {
        let data = SubagentToolData(
            toolCallId: "tc-r",
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

    // MARK: - Event Limit

    func testAddForwardedEvent_enforcesMaxEventsPerSubagent() {
        spawnDefault()
        // Add 510 events (exceeds 500 limit)
        for i in 0..<510 {
            sut.addForwardedEvent(
                subagentSessionId: "sub-1",
                eventType: "tool_start",
                eventData: AnyCodable(["toolName": "bash", "toolCallId": "t\(i)"]),
                timestamp: "2026-01-01T00:00:00Z"
            )
        }

        let events = sut.subagentEvents["sub-1"] ?? []
        XCTAssertLessThanOrEqual(events.count, 500, "Events should be capped at maxEventsPerSubagent")
    }
}
