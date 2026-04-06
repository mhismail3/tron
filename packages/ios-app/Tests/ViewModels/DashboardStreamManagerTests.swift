import XCTest
@testable import TronMobile

// MARK: - SessionStreamBuffer Tests

@MainActor
final class SessionStreamBufferTests: XCTestCase {

    // MARK: - Text Delta Coalescing

    func testAppendTextDeltaCoalesces() {
        var buffer = SessionStreamBuffer()
        buffer.appendTextDelta("Hello")
        buffer.appendTextDelta(" World")

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].text, "Hello World")
        XCTAssertEqual(buffer.lines[0].kind, .text)
    }

    func testAppendTextDeltaKeepsFirstLine() {
        var buffer = SessionStreamBuffer()
        buffer.appendTextDelta("First line\nSecond line\nThird line")

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].text, "First line")
    }

    func testAppendTextDeltaTruncatesLongFirstLine() {
        var buffer = SessionStreamBuffer()
        let longText = String(repeating: "A", count: 250)
        buffer.appendTextDelta(longText)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].text.count, DashboardConstants.maxAssistantTextLength)
        XCTAssertTrue(buffer.lines[0].text.hasPrefix("AAA"))
    }

    // MARK: - Tool Start

    func testToolStartCreatesNewLine() {
        var buffer = SessionStreamBuffer()
        buffer.appendTextDelta("some text")
        buffer.addToolStart(name: "Edit", arguments: nil)

        XCTAssertEqual(buffer.lines.count, 2)
        XCTAssertEqual(buffer.lines[0].kind, .text)
        XCTAssertEqual(buffer.lines[1].kind, .toolStart)
    }

    func testToolStartExtractsSummaryFileName() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Edit", arguments: ["file_path": AnyCodable("/a/b/c.rs")])

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].text, "Edit")
        XCTAssertEqual(buffer.lines[0].summary, "c.rs")
    }

    func testToolStartExtractsSummaryBashCommand() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Bash", arguments: ["command": AnyCodable("cargo test")])

        XCTAssertEqual(buffer.lines[0].text, "Bash")
        XCTAssertEqual(buffer.lines[0].summary, "cargo test")
    }

    func testToolStartExtractsSummaryGrepPattern() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Grep", arguments: ["pattern": AnyCodable("TODO")])

        XCTAssertEqual(buffer.lines[0].text, "Grep")
        XCTAssertEqual(buffer.lines[0].summary, "\"TODO\"")
    }

    func testToolStartTruncatesLongSummary() {
        var buffer = SessionStreamBuffer()
        let longCommand = String(repeating: "x", count: 60)
        buffer.addToolStart(name: "Bash", arguments: ["command": AnyCodable(longCommand)])

        XCTAssertNotNil(buffer.lines[0].summary)
        // ToolRegistry uses ToolArgumentParser.truncate which appends "..."
        XCTAssertTrue(buffer.lines[0].summary!.hasSuffix("..."))
    }

    func testToolStartUnknownToolNoSummary() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "CustomTool", arguments: nil)

        XCTAssertEqual(buffer.lines[0].text, "CustomTool")
        XCTAssertNil(buffer.lines[0].summary)
    }

    // MARK: - Tool End

    func testToolEndCreatesLineSuccess() {
        var buffer = SessionStreamBuffer()
        buffer.addToolEnd(name: "Edit", success: true)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .toolEnd)
        XCTAssertEqual(buffer.lines[0].toolName, "Edit")
        XCTAssertEqual(buffer.lines[0].status, .success)
    }

    func testToolEndCreatesLineFailure() {
        var buffer = SessionStreamBuffer()
        buffer.addToolEnd(name: "Bash", success: false)

        XCTAssertEqual(buffer.lines[0].toolName, "Bash")
        XCTAssertEqual(buffer.lines[0].status, .error)
    }

    // MARK: - Subagent Events

    func testSubagentSpawnCreatesLine() {
        var buffer = SessionStreamBuffer()
        buffer.addSubagentSpawn(task: "exploring codebase")

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .subagentSpawn)
        XCTAssertTrue(buffer.lines[0].text.contains("exploring codebase"))
    }

    func testSubagentSpawnTruncatesLongTask() {
        var buffer = SessionStreamBuffer()
        let longTask = String(repeating: "a", count: 80)
        buffer.addSubagentSpawn(task: longTask)

        // "Agent: " (7) + 47 chars + "…" (1) = 55
        XCTAssertTrue(buffer.lines[0].text.count <= 55)
    }

    func testSubagentCompleteCreatesLine() {
        var buffer = SessionStreamBuffer()
        buffer.addSubagentComplete(turns: 3)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .subagentDone)
        XCTAssertTrue(buffer.lines[0].text.contains("3"))
    }

    func testSubagentFailedCreatesLine() {
        var buffer = SessionStreamBuffer()
        buffer.addSubagentFailed(error: "timeout")

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .subagentFailed)
        XCTAssertTrue(buffer.lines[0].text.contains("timeout"))
    }

    // MARK: - Thinking

    func testSetThinkingCreatesLine() {
        var buffer = SessionStreamBuffer()
        buffer.setThinking()

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .thinking)
    }

    func testSetThinkingIdempotent() {
        var buffer = SessionStreamBuffer()
        buffer.setThinking()
        buffer.setThinking()
        buffer.setThinking()

        XCTAssertEqual(buffer.lines.count, 1, "Should not add duplicate thinking lines")
    }

    func testTextDeltaReplacesThinkingLine() {
        var buffer = SessionStreamBuffer()
        buffer.setThinking()
        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .thinking)

        buffer.appendTextDelta("Hello")

        // Thinking line should be removed, replaced with text
        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .text)
        XCTAssertEqual(buffer.lines[0].text, "Hello")
    }

    // MARK: - Error

    func testErrorCreatesLine() {
        var buffer = SessionStreamBuffer()
        buffer.addError(message: "Something went wrong")

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .error)
        XCTAssertTrue(buffer.lines[0].text.contains("Something went wrong"))
    }

    func testErrorTruncatesLongMessage() {
        var buffer = SessionStreamBuffer()
        let longMessage = String(repeating: "x", count: 120)
        buffer.addError(message: longMessage)

        XCTAssertTrue(buffer.lines[0].text.count <= 83) // 80 chars + "…" possible + prefix
    }

    func testTurnFailedCreatesLine() {
        var buffer = SessionStreamBuffer()
        buffer.addTurnFailed(error: "Token limit exceeded")

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .error)
        XCTAssertTrue(buffer.lines[0].text.contains("Token limit exceeded"))
    }

    // MARK: - Ring Buffer Cap

    func testLineCappedAtMax() {
        var buffer = SessionStreamBuffer()
        for i in 0..<12 {
            buffer.addError(message: "Error \(i)")
        }

        XCTAssertEqual(buffer.lines.count, DashboardConstants.maxStreamBufferLines)
        XCTAssertEqual(buffer.lines.last?.text, "Error 11")
        XCTAssertEqual(buffer.lines.first?.text, "Error 4")
    }

    // MARK: - Freeze / Clear

    func testFreezePreservesLines() {
        var buffer = SessionStreamBuffer()
        buffer.appendTextDelta("Hello")
        buffer.addToolStart(name: "Edit", arguments: nil)
        buffer.freeze()

        XCTAssertFalse(buffer.isActive)
        XCTAssertEqual(buffer.lines.count, 2)
    }

    func testFreezeStopsAcceptingEvents() {
        var buffer = SessionStreamBuffer()
        buffer.appendTextDelta("Hello")
        buffer.freeze()

        let lineCountBefore = buffer.lines.count
        buffer.appendTextDelta(" more text")
        buffer.addToolStart(name: "Edit", arguments: nil)
        buffer.addToolEnd(name: "Edit", success: true)
        buffer.addSubagentSpawn(task: "task")
        buffer.addSubagentComplete(turns: 1)
        buffer.addSubagentFailed(error: "err")
        buffer.setThinking()
        buffer.addError(message: "err")
        buffer.addTurnFailed(error: "err")

        XCTAssertEqual(buffer.lines.count, lineCountBefore, "No mutations after freeze")
    }

    func testClearRemovesAllLines() {
        var buffer = SessionStreamBuffer()
        buffer.appendTextDelta("Hello")
        buffer.addToolStart(name: "Edit", arguments: nil)
        buffer.freeze()
        buffer.clear()

        XCTAssertTrue(buffer.isActive)
        XCTAssertTrue(buffer.lines.isEmpty)
    }

    // MARK: - Text Line Transitions

    func testNewTextLineAfterToolEnd() {
        var buffer = SessionStreamBuffer()
        buffer.appendTextDelta("first text")
        buffer.addToolStart(name: "Edit", arguments: nil)
        buffer.addToolEnd(name: "Edit", success: true)
        buffer.appendTextDelta("second text")

        // addToolEnd updates the toolStart in-place (no new line), so 3 lines total
        XCTAssertEqual(buffer.lines.count, 3)
        XCTAssertEqual(buffer.lines[0].kind, .text)
        XCTAssertEqual(buffer.lines[0].text, "first text")
        XCTAssertEqual(buffer.lines[1].kind, .toolStart)
        XCTAssertEqual(buffer.lines[1].status, .success)
        XCTAssertEqual(buffer.lines[2].kind, .text)
        XCTAssertEqual(buffer.lines[2].text, "second text")
    }
}

// MARK: - DashboardStreamManager Tests

@MainActor
final class DashboardStreamManagerTests: XCTestCase {

    // MARK: - Buffer Creation

    func testHandleTextDeltaCreatesBuffer() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "Hello")
        manager.flush()

        XCTAssertTrue(manager.hasContent(for: "s1"))
    }

    func testHandleTextDeltaRoutes() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "Hello")
        manager.handleTextDelta(sessionId: "s2", delta: "World")
        manager.flush()

        let s1Lines = manager.visibleLines(for: "s1", count: 3)
        let s2Lines = manager.visibleLines(for: "s2", count: 3)

        XCTAssertEqual(s1Lines.count, 1)
        XCTAssertEqual(s1Lines[0].text, "Hello")
        XCTAssertEqual(s2Lines.count, 1)
        XCTAssertEqual(s2Lines[0].text, "World")
    }

    // MARK: - Visible Lines

    func testVisibleLinesReturnsTail() {
        let manager = DashboardStreamManager()
        for i in 0..<6 {
            manager.handleToolStart(sessionId: "s1", toolName: "Tool\(i)", arguments: nil)
        }

        let visible = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(visible.count, 3)
        XCTAssertEqual(visible[0].text, "Tool3")
        XCTAssertEqual(visible[2].text, "Tool5")
    }

    func testVisibleLinesEmptyForUnknownSession() {
        let manager = DashboardStreamManager()

        let visible = manager.visibleLines(for: "unknown", count: 3)
        XCTAssertTrue(visible.isEmpty)
    }

    // MARK: - Has Content

    func testHasContentTrue() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "text")
        manager.flush()

        XCTAssertTrue(manager.hasContent(for: "s1"))
    }

    func testHasContentFalseEmpty() {
        let manager = DashboardStreamManager()

        XCTAssertFalse(manager.hasContent(for: "s1"))
    }

    // MARK: - Turn Start

    func testHandleTurnStartPreservesBufferAcrossToolTurns() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "old content")
        manager.handleToolStart(sessionId: "s1", toolName: "Edit", arguments: nil)
        XCTAssertTrue(manager.hasContent(for: "s1"))

        // Mid-processing turn start should NOT clear the buffer
        manager.handleTurnStart(sessionId: "s1")

        XCTAssertTrue(manager.hasContent(for: "s1"), "Buffer should persist across tool-use turns")
    }

    func testHandleTurnStartClearsAfterCompletion() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "old content")
        manager.flush()
        manager.handleComplete(sessionId: "s1")

        // New turn after completion (new user message) — fresh buffer
        manager.handleTurnStart(sessionId: "s1")

        XCTAssertFalse(manager.hasContent(for: "s1"), "Buffer should be fresh after completion + new turn")
        manager.handleTextDelta(sessionId: "s1", delta: "new content")
        manager.flush()
        XCTAssertTrue(manager.hasContent(for: "s1"))
    }

    func testHandleTurnStartCreatesBuffer() {
        let manager = DashboardStreamManager()
        manager.handleTurnStart(sessionId: "new-session")

        // Buffer created but empty
        XCTAssertFalse(manager.hasContent(for: "new-session"))
        // But we can now write to it
        manager.handleTextDelta(sessionId: "new-session", delta: "text")
        manager.flush()
        XCTAssertTrue(manager.hasContent(for: "new-session"))
    }

    // MARK: - Complete / Freeze

    func testHandleCompleteFreezes() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "result")
        manager.flush()
        manager.handleComplete(sessionId: "s1")

        // Content preserved
        XCTAssertTrue(manager.hasContent(for: "s1"))

        // Further events ignored
        manager.handleTextDelta(sessionId: "s1", delta: " more")
        manager.flush()
        let lines = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "result")
    }

    func testHandleCompleteNoopMissingSession() {
        let manager = DashboardStreamManager()
        // Should not crash or create a buffer
        manager.handleComplete(sessionId: "nonexistent")
        XCTAssertFalse(manager.hasContent(for: "nonexistent"))
    }

    // MARK: - Clear

    func testClearBufferRemoves() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "text")
        manager.flush()
        manager.clearBuffer(for: "s1")

        XCTAssertFalse(manager.hasContent(for: "s1"))
        XCTAssertTrue(manager.visibleLines(for: "s1", count: 3).isEmpty)
    }

    func testClearAllRemovesEverything() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "a")
        manager.handleTextDelta(sessionId: "s2", delta: "b")
        manager.flush()
        manager.clearAll()

        XCTAssertFalse(manager.hasContent(for: "s1"))
        XCTAssertFalse(manager.hasContent(for: "s2"))
    }

    // MARK: - Multi-Session Independence

    func testMultipleSessionsIndependent() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "session1")
        manager.flush()
        manager.handleToolStart(sessionId: "s2", toolName: "Edit", arguments: nil)

        let s1 = manager.visibleLines(for: "s1", count: 3)
        let s2 = manager.visibleLines(for: "s2", count: 3)

        XCTAssertEqual(s1.count, 1)
        XCTAssertEqual(s1[0].kind, .text)
        XCTAssertEqual(s2.count, 1)
        XCTAssertEqual(s2[0].kind, .toolStart)
    }

    // MARK: - Error Handling

    func testHandleErrorFreezes() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "partial")
        manager.flush()
        manager.handleError(sessionId: "s1", message: "API error")

        // Error line added
        let lines = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].kind, .error)

        // Frozen — no further events
        manager.handleTextDelta(sessionId: "s1", delta: "ignored")
        manager.flush()
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 5).count, 2)
    }

    func testHandleTurnFailedFreezes() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "partial")
        manager.flush()
        manager.handleTurnFailed(sessionId: "s1", error: "Token limit exceeded")

        let lines = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].kind, .error)

        // Frozen
        manager.handleTextDelta(sessionId: "s1", delta: "ignored")
        manager.flush()
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 5).count, 2)
    }

    // MARK: - Events After Freeze

    func testEventsIgnoredAfterFreeze() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "text")
        manager.flush()
        manager.handleComplete(sessionId: "s1")

        let before = manager.visibleLines(for: "s1", count: 10)

        manager.handleTextDelta(sessionId: "s1", delta: "more")
        manager.handleToolStart(sessionId: "s1", toolName: "Edit", arguments: nil)
        manager.handleThinkingDelta(sessionId: "s1")
        manager.handleSubagentSpawned(sessionId: "s1", task: "task", toolCallId: "tc1", subagentSessionId: "sub1")
        manager.flush()

        let after = manager.visibleLines(for: "s1", count: 10)
        XCTAssertEqual(before.count, after.count)
    }

    // MARK: - Nil Arguments

    func testToolStartWithNilArguments() {
        let manager = DashboardStreamManager()
        manager.handleToolStart(sessionId: "s1", toolName: "Edit", arguments: nil)

        let lines = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Edit")
    }

    // MARK: - Hook Subagent Suppression

    func testHookSubagentSuppressed() {
        let manager = DashboardStreamManager()
        manager.handleSubagentSpawned(sessionId: "s1", task: "hook task", toolCallId: nil, subagentSessionId: "sub1")

        XCTAssertFalse(manager.hasContent(for: "s1"))
    }

    func testUserSubagentShown() {
        let manager = DashboardStreamManager()
        manager.handleSubagentSpawned(sessionId: "s1", task: "user task", toolCallId: "tc1", subagentSessionId: "sub1")

        XCTAssertTrue(manager.hasContent(for: "s1"))
        let lines = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(lines[0].kind, .subagentSpawn)
    }

    func testHookSubagentCompleteSuppressed() {
        let manager = DashboardStreamManager()
        manager.handleSubagentSpawned(sessionId: "s1", task: "hook", toolCallId: nil, subagentSessionId: "sub1")
        manager.handleSubagentCompleted(sessionId: "s1", turns: 3, subagentSessionId: "sub1")

        XCTAssertFalse(manager.hasContent(for: "s1"))
    }

    func testHookSubagentFailedSuppressed() {
        let manager = DashboardStreamManager()
        manager.handleSubagentSpawned(sessionId: "s1", task: "hook", toolCallId: nil, subagentSessionId: "sub1")
        manager.handleSubagentFailed(sessionId: "s1", error: "timeout", subagentSessionId: "sub1")

        XCTAssertFalse(manager.hasContent(for: "s1"))
    }

    // MARK: - Post-Completion Event Blocking

    func testPostCompletionEventsIgnored() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "done")
        manager.flush()
        manager.handleComplete(sessionId: "s1")

        // Events after completion should not create a new buffer
        manager.handleTextDelta(sessionId: "s1", delta: "hook output")
        manager.handleToolStart(sessionId: "s1", toolName: "Edit", arguments: nil)
        manager.handleThinkingDelta(sessionId: "s1")
        manager.flush()

        let lines = manager.visibleLines(for: "s1", count: 10)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "done")
    }

    func testPostCompletionToolStartIgnored() {
        let manager = DashboardStreamManager()
        manager.handleComplete(sessionId: "s1")

        manager.handleToolStart(sessionId: "s1", toolName: "Edit", arguments: nil)
        XCTAssertFalse(manager.hasContent(for: "s1"))
    }

    func testTurnStartAfterCompleteAllowsNewBuffer() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "first turn")
        manager.flush()
        manager.handleComplete(sessionId: "s1")

        manager.handleTurnStart(sessionId: "s1")
        manager.handleTextDelta(sessionId: "s1", delta: "second turn")
        manager.flush()

        let lines = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "second turn")
    }

    // MARK: - Snapshot

    func testSnapshotLinesConvertsCorrectly() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "hello")
        manager.flush()
        manager.handleToolStart(sessionId: "s1", toolName: "Edit", arguments: nil)

        let snapshot = manager.snapshotLines(for: "s1", count: 3)
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot[0].kind, .text)
        XCTAssertEqual(snapshot[0].text, "hello")
        XCTAssertEqual(snapshot[1].kind, .toolStart)
        XCTAssertEqual(snapshot[1].text, "Edit")
    }

    func testSnapshotEmptyForUnknownSession() {
        let manager = DashboardStreamManager()
        let snapshot = manager.snapshotLines(for: "unknown", count: 3)
        XCTAssertTrue(snapshot.isEmpty)
    }
}

// MARK: - Parallel Tool & Tool End Tests

@MainActor
final class SessionStreamBufferToolTests: XCTestCase {

    func testParallelToolStartsShowIndividualChips() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Edit", arguments: nil)
        buffer.addToolStart(name: "Bash", arguments: nil)

        XCTAssertEqual(buffer.lines.count, 2)
        XCTAssertEqual(buffer.lines[0].kind, .toolStart)
        XCTAssertEqual(buffer.lines[0].toolName, "Edit")
        XCTAssertEqual(buffer.lines[1].kind, .toolStart)
        XCTAssertEqual(buffer.lines[1].toolName, "Bash")
    }

    func testToolEndUpdatesExistingToolStartInPlace() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Edit", arguments: ["file_path": AnyCodable("/a/b/c.rs")])
        XCTAssertEqual(buffer.lines[0].status, .running)

        buffer.addToolEnd(name: "Edit", success: true, durationMs: 50)

        // Same line count — updated in place
        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .toolStart)
        XCTAssertEqual(buffer.lines[0].status, .success)
        XCTAssertEqual(buffer.lines[0].duration, "50ms")
        XCTAssertEqual(buffer.lines[0].summary, "c.rs") // preserved
    }

    func testToolEndErrorStatus() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Read", arguments: ["file_path": AnyCodable("/missing.txt")])
        buffer.addToolEnd(name: "Read", success: false, durationMs: 2)

        XCTAssertEqual(buffer.lines[0].status, .error)
        XCTAssertEqual(buffer.lines[0].duration, "2ms")
    }

    func testParallelToolEndsUpdateCorrectChips() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Edit", arguments: nil)
        buffer.addToolStart(name: "Bash", arguments: nil)
        buffer.addToolStart(name: "Read", arguments: nil)

        buffer.addToolEnd(name: "Bash", success: true, durationMs: 100)
        buffer.addToolEnd(name: "Edit", success: true, durationMs: 50)
        buffer.addToolEnd(name: "Read", success: false, durationMs: 5)

        XCTAssertEqual(buffer.lines.count, 3)
        XCTAssertEqual(buffer.lines[0].toolName, "Edit")
        XCTAssertEqual(buffer.lines[0].status, .success)
        XCTAssertEqual(buffer.lines[1].toolName, "Bash")
        XCTAssertEqual(buffer.lines[1].status, .success)
        XCTAssertEqual(buffer.lines[2].toolName, "Read")
        XCTAssertEqual(buffer.lines[2].status, .error)
    }

    func testToolEndWithDurationFormatting() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Bash", arguments: nil)
        buffer.addToolEnd(name: "Bash", success: true, durationMs: 1500)

        XCTAssertEqual(buffer.lines[0].duration, "1.5s")
    }

    func testToolEndFallbackWhenNoMatchingStart() {
        var buffer = SessionStreamBuffer()
        buffer.addToolEnd(name: "Bash", success: true, durationMs: 100)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .toolEnd)
        XCTAssertEqual(buffer.lines[0].toolName, "Bash")
    }
    // MARK: - Tool Call ID Matching

    func testToolEndMatchesByToolCallIdFirst() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Read", toolCallId: "tc1", arguments: nil)
        buffer.addToolStart(name: "Read", toolCallId: "tc2", arguments: nil)

        buffer.addToolEnd(name: "Read", toolCallId: "tc1", success: true, durationMs: 50)

        XCTAssertEqual(buffer.lines[0].status, .success)
        XCTAssertEqual(buffer.lines[0].duration, "50ms")
        XCTAssertEqual(buffer.lines[1].status, .running) // tc2 unchanged
    }

    func testToolEndFallsBackToNameWhenNoToolCallId() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Edit", toolCallId: nil, arguments: nil)
        buffer.addToolEnd(name: "Edit", toolCallId: nil, success: true, durationMs: 100)

        XCTAssertEqual(buffer.lines[0].status, .success)
    }

    func testToolEndWithMismatchedIdFallsBackToName() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Bash", toolCallId: "tc1", arguments: nil)
        buffer.addToolEnd(name: "Bash", toolCallId: "tc999", success: true, durationMs: 10)

        // No matching ID → falls back to name match (finds tc1 which is still running)
        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].status, .success)
    }

    func testConcurrentSameNameToolsResolveCorrectly() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Read", toolCallId: "tc1", arguments: ["file_path": AnyCodable("/a.txt")])
        buffer.addToolStart(name: "Read", toolCallId: "tc2", arguments: ["file_path": AnyCodable("/b.txt")])
        buffer.addToolStart(name: "Read", toolCallId: "tc3", arguments: ["file_path": AnyCodable("/c.txt")])

        // Complete in reverse order
        buffer.addToolEnd(name: "Read", toolCallId: "tc3", success: true, durationMs: 5)
        buffer.addToolEnd(name: "Read", toolCallId: "tc1", success: false, durationMs: 100)
        buffer.addToolEnd(name: "Read", toolCallId: "tc2", success: true, durationMs: 50)

        XCTAssertEqual(buffer.lines[0].status, .error)    // tc1
        XCTAssertEqual(buffer.lines[0].duration, "100ms")
        XCTAssertEqual(buffer.lines[1].status, .success)   // tc2
        XCTAssertEqual(buffer.lines[1].duration, "50ms")
        XCTAssertEqual(buffer.lines[2].status, .success)   // tc3
        XCTAssertEqual(buffer.lines[2].duration, "5ms")
    }
}

// MARK: - Tool Metadata Tests

@MainActor
final class SessionStreamBufferToolMetaTests: XCTestCase {

    func testToolStartHasIconAndColor() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Bash", arguments: nil)

        XCTAssertEqual(buffer.lines[0].icon, "terminal")
        XCTAssertEqual(buffer.lines[0].iconColor, .tronEmerald)
    }

    func testToolStartUnknownToolHasDefaultIcon() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "SomeCustomMCPTool", arguments: nil)

        // ToolRegistry default: gearshape icon, tronTextMuted color
        XCTAssertEqual(buffer.lines[0].icon, "gearshape")
        XCTAssertEqual(buffer.lines[0].iconColor, .tronTextMuted)
    }

    func testToolEndHasIconAndColor() {
        var buffer = SessionStreamBuffer()
        buffer.addToolEnd(name: "Edit", success: true)

        XCTAssertEqual(buffer.lines[0].icon, "pencil.line")
        XCTAssertEqual(buffer.lines[0].iconColor, .orange)
    }

    func testToolStartHasToolName() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Edit", arguments: ["file_path": AnyCodable("/a/b/c.rs")])

        XCTAssertEqual(buffer.lines[0].toolName, "Edit")
        XCTAssertEqual(buffer.lines[0].displayName, "Edit")
        XCTAssertEqual(buffer.lines[0].text, "Edit")
        XCTAssertEqual(buffer.lines[0].summary, "c.rs")
    }

    func testToolStartDisplayNameFromRegistry() {
        var buffer = SessionStreamBuffer()
        // "WebSearch" → ToolRegistry displayName is "Web Search"
        buffer.addToolStart(name: "WebSearch", arguments: nil)
        XCTAssertEqual(buffer.lines[0].toolName, "WebSearch")
        XCTAssertEqual(buffer.lines[0].displayName, "Web Search")
    }

    func testParallelToolStartsEachHaveIcon() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Edit", arguments: nil)
        buffer.addToolStart(name: "Bash", arguments: nil)

        XCTAssertEqual(buffer.lines.count, 2)
        XCTAssertEqual(buffer.lines[0].icon, "pencil.line")
        XCTAssertEqual(buffer.lines[1].icon, "terminal")
    }
}

// MARK: - Snapshot & Visible Lines Tests

@MainActor
final class DashboardStreamManagerSnapshotTests: XCTestCase {

    func testSnapshotIncludesIconColorAndDisplayName() {
        let manager = DashboardStreamManager()
        manager.handleToolStart(sessionId: "s1", toolName: "Bash", arguments: nil)

        let snapshot = manager.snapshotLines(for: "s1", count: 3)
        XCTAssertEqual(snapshot[0].icon, "terminal")
        XCTAssertEqual(snapshot[0].iconColor, .tronEmerald)
        XCTAssertEqual(snapshot[0].displayName, "Bash")
    }

    func testSnapshotDisplayNameMatchesRegistry() {
        let manager = DashboardStreamManager()
        manager.handleToolStart(sessionId: "s1", toolName: "WebFetch", arguments: nil)

        let snapshot = manager.snapshotLines(for: "s1", count: 3)
        XCTAssertEqual(snapshot[0].displayName, "Web Fetch")
    }

    func testVisibleLinesDefaultCount5() {
        let manager = DashboardStreamManager()
        for i in 0..<8 {
            manager.handleTextDelta(sessionId: "s1", delta: "line\(i)\n")
            // Force new text line by inserting a tool between
            if i < 7 {
                manager.handleToolStart(sessionId: "s1", toolName: "Tool\(i)", arguments: nil)
            }
        }
        manager.flush()

        // Default count should return up to 5
        let lines = manager.visibleLines(for: "s1")
        XCTAssertEqual(lines.count, 5)
    }

    func testTextDeltasBatchedUntilFlush() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "Hello")

        // Before flush, buffers should not reflect the text delta
        XCTAssertFalse(manager.hasContent(for: "s1"), "Text deltas should be staged, not immediately visible")

        // After flush, content appears
        manager.flush()
        XCTAssertTrue(manager.hasContent(for: "s1"))
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 1)[0].text, "Hello")
    }

    func testStructuralEventsFlushedImmediately() {
        let manager = DashboardStreamManager()
        manager.handleToolStart(sessionId: "s1", toolName: "Edit", arguments: nil)

        // Tool start should be immediately visible (no flush needed)
        XCTAssertTrue(manager.hasContent(for: "s1"))
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 1)[0].kind, .toolStart)
    }

    func testToolStartFlushesPriorTextDelta() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "thinking...")
        // Text delta is staged
        XCTAssertFalse(manager.hasContent(for: "s1"))

        // Tool start should flush the pending text delta too
        manager.handleToolStart(sessionId: "s1", toolName: "Bash", arguments: nil)
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 5).count, 2)
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 5)[0].kind, .text)
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 5)[1].kind, .toolStart)
    }
    // MARK: - activityLines(for:persisted:) Data Source

    func testActivityLinesReturnsLiveBufferWhenAvailable() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "live")
        manager.flush()

        let persisted = [ActivityLine(kind: .text, text: "old persisted")]
        let result = manager.activityLines(for: "s1", persisted: persisted)
        XCTAssertEqual(result[0].text, "live")
    }

    func testActivityLinesFallsBackToPersistedWhenNoBuffer() {
        let manager = DashboardStreamManager()
        let persisted = [ActivityLine(kind: .text, text: "persisted")]
        let result = manager.activityLines(for: "s1", persisted: persisted)
        XCTAssertEqual(result[0].text, "persisted")
    }

    func testActivityLinesReturnsEmptyWhenNeitherExists() {
        let manager = DashboardStreamManager()
        let result = manager.activityLines(for: "s1", persisted: nil)
        XCTAssertTrue(result.isEmpty)
    }

    func testActivityLinesRespectsCount() {
        let manager = DashboardStreamManager()
        for i in 0..<6 {
            manager.handleToolStart(sessionId: "s1", toolName: "Tool\(i)", arguments: nil)
        }
        let result = manager.activityLines(for: "s1", persisted: nil, count: 3)
        XCTAssertEqual(result.count, 3)
    }
}

// MARK: - ContentExtractor Activity Lines Tests

@MainActor
final class ContentExtractorActivityLineTests: XCTestCase {

    /// Build a SessionEvent with the given type and payload.
    private func makeEvent(type: String, payload: [String: AnyCodable]) -> SessionEvent {
        SessionEvent(
            id: UUID().uuidString,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "ws",
            type: type,
            timestamp: "2026-01-01T00:00:00Z",
            sequence: 0,
            payload: payload
        )
    }

    func testExtractActivityLinesWithToolUseSummary() {
        // Simulate a message.assistant event with a tool_use content block
        let content: [Any] = [
            [
                "type": "tool_use",
                "id": "toolu_abc",
                "name": "Bash",
                "input": ["command": "cargo test"]
            ] as [String: Any]
        ]

        let assistantEvent = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable(content)
        ])

        let lines = ContentExtractor.extractActivityLines(from: [assistantEvent])

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .toolStart)
        XCTAssertEqual(lines[0].displayName, "Bash")
        // Summary should be extracted from input arguments
        XCTAssertNotNil(lines[0].summary, "Summary should be extracted from tool input")
        XCTAssertTrue(lines[0].summary?.contains("cargo test") == true,
                      "Bash summary should contain the command, got: \(lines[0].summary ?? "nil")")
    }

    func testExtractActivityLinesWithMultipleTools() {
        let content: [Any] = [
            [
                "type": "tool_use",
                "id": "toolu_1",
                "name": "Read",
                "input": ["file_path": "/Users/test/example.swift"]
            ] as [String: Any],
            [
                "type": "text",
                "text": "Let me read that file."
            ] as [String: Any],
            [
                "type": "tool_use",
                "id": "toolu_2",
                "name": "WebSearch",
                "input": ["query": "current time UTC"]
            ] as [String: Any]
        ]

        let toolResult1 = makeEvent(type: "tool.result", payload: [
            "tool_use_id": AnyCodable("toolu_1"),
            "is_error": AnyCodable(false),
            "duration_ms": AnyCodable(25)
        ])

        let toolResult2 = makeEvent(type: "tool.result", payload: [
            "tool_use_id": AnyCodable("toolu_2"),
            "is_error": AnyCodable(false),
            "duration_ms": AnyCodable(703)
        ])

        let assistantEvent = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable(content)
        ])

        let lines = ContentExtractor.extractActivityLines(from: [assistantEvent, toolResult1, toolResult2])

        // Should have: Read tool, text, WebSearch tool
        let toolLines = lines.filter { $0.kind == .toolStart }
        XCTAssertEqual(toolLines.count, 2)

        // Read tool should have file summary
        let readLine = toolLines.first { $0.displayName == "Read" }
        XCTAssertNotNil(readLine)
        XCTAssertEqual(readLine?.summary, "example.swift")
        XCTAssertEqual(readLine?.duration, "25ms")
        XCTAssertEqual(readLine?.status, .success)

        // WebSearch tool should have query summary
        let searchLine = toolLines.first { $0.displayName == "Web Search" }
        XCTAssertNotNil(searchLine)
        XCTAssertNotNil(searchLine?.summary)
        XCTAssertTrue(searchLine?.summary?.contains("current time UTC") == true)
        XCTAssertEqual(searchLine?.duration, "703ms")
    }

    func testExtractActivityLinesWithAnyCodablePayload() {
        // Simulate what AnyCodable.init(from decoder:) produces:
        // Nested dicts stored as [String: Any], not [String: AnyCodable]
        let toolUseBlock: [String: Any] = [
            "type": "tool_use",
            "id": "toolu_xyz",
            "name": "Edit",
            "input": ["file_path": "/src/main.rs", "old_string": "foo", "new_string": "bar"] as [String: Any]
        ]

        let content: [Any] = [toolUseBlock]

        let assistantEvent = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable(content)
        ])

        let lines = ContentExtractor.extractActivityLines(from: [assistantEvent])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].displayName, "Edit")
        XCTAssertEqual(lines[0].summary, "main.rs")
    }

    func testExtractActivityLinesWithArgumentsKey() {
        // Server stores tool_use blocks with "arguments" key, NOT "input"
        // This is the actual production format
        let content: [Any] = [
            [
                "type": "tool_use",
                "id": "toolu_abc",
                "name": "Bash",
                "arguments": ["command": "cargo test"] as [String: Any]
            ] as [String: Any],
            [
                "type": "tool_use",
                "id": "toolu_def",
                "name": "Read",
                "arguments": ["file_path": "/tmp/test.txt"] as [String: Any]
            ] as [String: Any]
        ]

        let assistantEvent = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable(content)
        ])

        let lines = ContentExtractor.extractActivityLines(from: [assistantEvent])
        XCTAssertEqual(lines.count, 2)

        XCTAssertEqual(lines[0].displayName, "Bash")
        XCTAssertNotNil(lines[0].summary, "Should extract summary from 'arguments' key")
        XCTAssertTrue(lines[0].summary?.contains("cargo test") == true)

        XCTAssertEqual(lines[1].displayName, "Read")
        XCTAssertEqual(lines[1].summary, "test.txt")
    }
}

// MARK: - ActivityLine Tests

@MainActor
final class ActivityLineTests: XCTestCase {

    func testActivityLineCodable() throws {
        let line = ActivityLine(kind: .toolStart, text: "Edit server.rs")
        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(ActivityLine.self, from: data)
        XCTAssertEqual(decoded.kind, .toolStart)
        XCTAssertEqual(decoded.text, "Edit server.rs")
    }

    func testActivityLineWithOptionalFields() throws {
        let line = ActivityLine(kind: .toolStart, text: "Bash", icon: "terminal", iconColor: .tronEmerald)
        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(ActivityLine.self, from: data)
        XCTAssertEqual(decoded.icon, "terminal")
        XCTAssertEqual(decoded.iconColor, .tronEmerald)
    }

    func testActivityLineWithNilFields() throws {
        let line = ActivityLine(kind: .text, text: "hello")
        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(ActivityLine.self, from: data)
        XCTAssertNil(decoded.icon)
        XCTAssertNil(decoded.iconColor)
    }

    func testActivityLineCodableWithEnumFields() throws {
        let line = ActivityLine(kind: .toolStart, text: "Edit", icon: "pencil.line",
                                iconColor: .orange, status: .running)
        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(ActivityLine.self, from: data)
        XCTAssertEqual(decoded.kind, .toolStart)
        XCTAssertEqual(decoded.iconColor, .orange)
        XCTAssertEqual(decoded.status, .running)
        // id should be fresh (not persisted)
        XCTAssertNotEqual(decoded.id, line.id)
    }

    func testActivityLineCodableOmitsTransientFields() throws {
        let line = ActivityLine(kind: .text, text: "hello")
        let data = try JSONEncoder().encode(line)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["id"], "id should be excluded from encoding")
        XCTAssertNil(json["toolCallId"], "toolCallId should be excluded from encoding")
    }

    func testActivityLineEqualityIgnoresId() {
        let a = ActivityLine(kind: .text, text: "hello")
        let b = ActivityLine(kind: .text, text: "hello")
        XCTAssertEqual(a, b, "Same content should be equal")
        XCTAssertNotEqual(a.id, b.id, "IDs should be unique")
    }

    func testToolColorResolvesAllCases() {
        for toolColor in ToolColor.allCases {
            _ = toolColor.color // Should not crash
        }
    }

    func testToolColorFromDescriptorName() {
        XCTAssertEqual(ToolColor(fromDescriptorName: "tronEmerald"), .tronEmerald)
        XCTAssertEqual(ToolColor(fromDescriptorName: "orange"), .orange)
        XCTAssertEqual(ToolColor(fromDescriptorName: "unknownColor"), .tronTextMuted)
    }
}
