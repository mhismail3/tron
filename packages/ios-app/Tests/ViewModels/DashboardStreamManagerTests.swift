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

    func testAppendTextDeltaTruncatesTail() {
        var buffer = SessionStreamBuffer()
        let longText = String(repeating: "A", count: 150)
        buffer.appendTextDelta(longText)
        // Now add more to exceed maxTextLineLength (200)
        let moreText = String(repeating: "B", count: 100)
        buffer.appendTextDelta(moreText)

        XCTAssertEqual(buffer.lines.count, 1)
        // Total would be 250, should keep tail 200
        XCTAssertEqual(buffer.lines[0].text.count, SessionStreamBuffer.maxTextLineLength)
        // Tail should be all B's and some A's
        XCTAssertTrue(buffer.lines[0].text.hasSuffix(moreText))
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

    func testToolStartFormatsFileName() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Edit", arguments: ["file_path": AnyCodable("/a/b/c.rs")])

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].text, "Edit c.rs")
    }

    func testToolStartFormatsBashCommand() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Bash", arguments: ["command": AnyCodable("cargo test")])

        XCTAssertEqual(buffer.lines[0].text, "$ cargo test")
    }

    func testToolStartFormatsGrepPattern() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "Grep", arguments: ["pattern": AnyCodable("TODO")])

        XCTAssertEqual(buffer.lines[0].text, "Grep \"TODO\"")
    }

    func testToolStartFormatsBashTruncatesLongCommand() {
        var buffer = SessionStreamBuffer()
        let longCommand = String(repeating: "x", count: 60)
        buffer.addToolStart(name: "Bash", arguments: ["command": AnyCodable(longCommand)])

        XCTAssertTrue(buffer.lines[0].text.count <= 44) // "$ " + 40 chars + "…"
        XCTAssertTrue(buffer.lines[0].text.hasSuffix("…"))
    }

    func testToolStartFormatsUnknownTool() {
        var buffer = SessionStreamBuffer()
        buffer.addToolStart(name: "CustomTool", arguments: nil)

        XCTAssertEqual(buffer.lines[0].text, "CustomTool")
    }

    // MARK: - Tool End

    func testToolEndCreatesLineSuccess() {
        var buffer = SessionStreamBuffer()
        buffer.addToolEnd(name: "Edit", success: true)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].kind, .toolEnd)
        XCTAssertEqual(buffer.lines[0].text, "✓ Edit")
    }

    func testToolEndCreatesLineFailure() {
        var buffer = SessionStreamBuffer()
        buffer.addToolEnd(name: "Bash", success: false)

        XCTAssertEqual(buffer.lines[0].text, "✗ Bash")
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
            buffer.addToolStart(name: "Tool\(i)", arguments: nil)
        }

        XCTAssertEqual(buffer.lines.count, SessionStreamBuffer.maxLines)
        // Oldest lines should have been dropped; last line should be Tool11
        XCTAssertEqual(buffer.lines.last?.text, "Tool11")
        // First line should be Tool4 (12 - 8 = 4)
        XCTAssertEqual(buffer.lines.first?.text, "Tool4")
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

        XCTAssertEqual(buffer.lines.count, 4)
        XCTAssertEqual(buffer.lines[0].kind, .text)
        XCTAssertEqual(buffer.lines[0].text, "first text")
        XCTAssertEqual(buffer.lines[3].kind, .text)
        XCTAssertEqual(buffer.lines[3].text, "second text")
    }
}

// MARK: - DashboardStreamManager Tests

@MainActor
final class DashboardStreamManagerTests: XCTestCase {

    // MARK: - Buffer Creation

    func testHandleTextDeltaCreatesBuffer() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "Hello")

        XCTAssertTrue(manager.hasContent(for: "s1"))
    }

    func testHandleTextDeltaRoutes() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "Hello")
        manager.handleTextDelta(sessionId: "s2", delta: "World")

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

        XCTAssertTrue(manager.hasContent(for: "s1"))
    }

    func testHasContentFalseEmpty() {
        let manager = DashboardStreamManager()

        XCTAssertFalse(manager.hasContent(for: "s1"))
    }

    // MARK: - Turn Start

    func testHandleTurnStartClearsOldBuffer() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "old content")
        XCTAssertTrue(manager.hasContent(for: "s1"))

        manager.handleTurnStart(sessionId: "s1")

        // Buffer exists but is empty (cleared)
        XCTAssertFalse(manager.hasContent(for: "s1"))
    }

    func testHandleTurnStartCreatesBuffer() {
        let manager = DashboardStreamManager()
        manager.handleTurnStart(sessionId: "new-session")

        // Buffer created but empty
        XCTAssertFalse(manager.hasContent(for: "new-session"))
        // But we can now write to it
        manager.handleTextDelta(sessionId: "new-session", delta: "text")
        XCTAssertTrue(manager.hasContent(for: "new-session"))
    }

    // MARK: - Complete / Freeze

    func testHandleCompleteFreezes() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "result")
        manager.handleComplete(sessionId: "s1")

        // Content preserved
        XCTAssertTrue(manager.hasContent(for: "s1"))

        // Further events ignored
        manager.handleTextDelta(sessionId: "s1", delta: " more")
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
        manager.clearBuffer(for: "s1")

        XCTAssertFalse(manager.hasContent(for: "s1"))
        XCTAssertTrue(manager.visibleLines(for: "s1", count: 3).isEmpty)
    }

    func testClearAllRemovesEverything() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "a")
        manager.handleTextDelta(sessionId: "s2", delta: "b")
        manager.clearAll()

        XCTAssertFalse(manager.hasContent(for: "s1"))
        XCTAssertFalse(manager.hasContent(for: "s2"))
    }

    // MARK: - Multi-Session Independence

    func testMultipleSessionsIndependent() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "session1")
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
        manager.handleError(sessionId: "s1", message: "API error")

        // Error line added
        let lines = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].kind, .error)

        // Frozen — no further events
        manager.handleTextDelta(sessionId: "s1", delta: "ignored")
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 5).count, 2)
    }

    func testHandleTurnFailedFreezes() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "partial")
        manager.handleTurnFailed(sessionId: "s1", error: "Token limit exceeded")

        let lines = manager.visibleLines(for: "s1", count: 3)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].kind, .error)

        // Frozen
        manager.handleTextDelta(sessionId: "s1", delta: "ignored")
        XCTAssertEqual(manager.visibleLines(for: "s1", count: 5).count, 2)
    }

    // MARK: - Events After Freeze

    func testEventsIgnoredAfterFreeze() {
        let manager = DashboardStreamManager()
        manager.handleTextDelta(sessionId: "s1", delta: "text")
        manager.handleComplete(sessionId: "s1")

        let before = manager.visibleLines(for: "s1", count: 10)

        manager.handleTextDelta(sessionId: "s1", delta: "more")
        manager.handleToolStart(sessionId: "s1", toolName: "Edit", arguments: nil)
        manager.handleThinkingDelta(sessionId: "s1")
        manager.handleSubagentSpawned(sessionId: "s1", task: "task")

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
}
