import XCTest
@testable import TronMobile

final class SessionEventSummaryTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        type: String,
        payload: [String: AnyCodable] = [:]
    ) -> SessionEvent {
        SessionEvent(
            id: "evt-\(UUID().uuidString)",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: type,
            timestamp: "2024-01-01T00:00:00Z",
            sequence: 1,
            payload: payload
        )
    }

    // MARK: - LLM Hook Result

    func testLlmHookResult_withHookName_showsHookName() {
        let event = makeEvent(type: "hook.llm_result", payload: [
            "hookName": AnyCodable("suggest-prompts"),
        ])
        XCTAssertEqual(event.summary, "Hook: suggest-prompts")
    }

    func testLlmHookResult_withDifferentHookName_showsHookName() {
        let event = makeEvent(type: "hook.llm_result", payload: [
            "hookName": AnyCodable("generate-title"),
        ])
        XCTAssertEqual(event.summary, "Hook: generate-title")
    }

    func testLlmHookResult_withoutHookName_showsFallback() {
        let event = makeEvent(type: "hook.llm_result")
        XCTAssertEqual(event.summary, "Hook completed")
    }

    func testLlmHookResult_withEmptyHookName_showsFallback() {
        let event = makeEvent(type: "hook.llm_result", payload: [
            "hookName": AnyCodable(""),
        ])
        XCTAssertEqual(event.summary, "Hook completed")
    }

    // MARK: - Subagent Events

    func testSubagentSpawned_summary() {
        let event = makeEvent(type: "subagent.spawned")
        XCTAssertEqual(event.summary, "Subagent spawned")
    }

    func testSubagentCompleted_summary() {
        let event = makeEvent(type: "subagent.completed")
        XCTAssertEqual(event.summary, "Subagent completed")
    }

    func testSubagentFailed_withError_showsError() {
        let event = makeEvent(type: "subagent.failed", payload: [
            "error": AnyCodable("timeout exceeded"),
        ])
        XCTAssertEqual(event.summary, "Subagent failed: timeout exceeded")
    }

    func testSubagentFailed_withLongError_truncates() {
        let longError = String(repeating: "x", count: 100)
        let event = makeEvent(type: "subagent.failed", payload: [
            "error": AnyCodable(longError),
        ])
        XCTAssertTrue(event.summary.hasPrefix("Subagent failed: "))
        XCTAssertTrue(event.summary.count <= "Subagent failed: ".count + 30)
    }

    func testSubagentFailed_withoutError_showsFallback() {
        let event = makeEvent(type: "subagent.failed")
        XCTAssertEqual(event.summary, "Subagent failed")
    }

    func testSubagentResultsConsumed_summary() {
        let event = makeEvent(type: "subagent.results_consumed")
        XCTAssertEqual(event.summary, "Results consumed")
    }

    func testNotificationSubagentResult_summary() {
        let event = makeEvent(type: "notification.subagent_result")
        XCTAssertEqual(event.summary, "Subagent result")
    }

    // MARK: - Turn Failed

    func testTurnFailed_withError_showsError() {
        let event = makeEvent(type: "turn.failed", payload: [
            "error": AnyCodable("rate limit hit"),
        ])
        XCTAssertEqual(event.summary, "Turn failed: rate limit hit")
    }

    func testTurnFailed_withLongError_truncates() {
        let longError = String(repeating: "a", count: 100)
        let event = makeEvent(type: "turn.failed", payload: [
            "error": AnyCodable(longError),
        ])
        XCTAssertTrue(event.summary.hasPrefix("Turn failed: "))
        XCTAssertTrue(event.summary.count <= "Turn failed: ".count + 30)
    }

    func testTurnFailed_withoutError_showsFallback() {
        let event = makeEvent(type: "turn.failed")
        XCTAssertEqual(event.summary, "Turn failed")
    }

    // MARK: - Memory

    func testMemoryRetained_summary() {
        let event = makeEvent(type: "memory.retained")
        XCTAssertEqual(event.summary, "Memory retained")
    }

    // MARK: - Unknown Event Formatting

    func testUnknownEvent_formatsRawType_dotSeparated() {
        let event = makeEvent(type: "foo.bar")
        XCTAssertEqual(event.summary, "Foo Bar")
    }

    func testUnknownEvent_formatsRawType_underscoreSeparated() {
        let event = makeEvent(type: "some_unknown_type")
        XCTAssertEqual(event.summary, "Some Unknown Type")
    }

    func testUnknownEvent_formatsRawType_mixed() {
        let event = makeEvent(type: "foo.bar_baz")
        XCTAssertEqual(event.summary, "Foo Bar Baz")
    }

    // MARK: - Existing Event Summaries (Spot Checks)

    func testSessionStart_showsModel() {
        let event = makeEvent(type: "session.start", payload: [
            "model": AnyCodable("claude-sonnet-4-6-20260404"),
        ])
        XCTAssertTrue(event.summary.hasPrefix("Session started"))
    }

    func testSessionStart_unknownModel() {
        let event = makeEvent(type: "session.start")
        XCTAssertTrue(event.summary.contains("unknown"))
    }

    func testCapabilityInvocation_showsModelToolName() {
        let event = makeEvent(type: "capability.invocation.started", payload: [
            "name": AnyCodable("Read"),
            "arguments": AnyCodable(["file_path": "/foo/bar.swift"]),
        ])
        XCTAssertTrue(event.summary.contains("Read"))
    }

    func testToolResult_success_showsDuration() {
        let event = makeEvent(type: "capability.invocation.completed", payload: [
            "isError": AnyCodable(false),
            "duration": AnyCodable(522),
        ])
        XCTAssertEqual(event.summary, "522ms • success")
    }

    func testToolResult_error_showsError() {
        let event = makeEvent(type: "capability.invocation.completed", payload: [
            "isError": AnyCodable(true),
        ])
        XCTAssertEqual(event.summary, "error")
    }

    func testMessageUser_showsContentPreview() {
        let event = makeEvent(type: "message.user", payload: [
            "content": AnyCodable("Hello world, this is a test message"),
        ])
        XCTAssertEqual(event.summary, "Hello world, this is a test message")
    }

    func testMessageUser_truncatesLongContent() {
        let longContent = String(repeating: "x", count: 100)
        let event = makeEvent(type: "message.user", payload: [
            "content": AnyCodable(longContent),
        ])
        XCTAssertTrue(event.summary.count <= 50)
    }

    func testWorktreeAcquired_withBranch() {
        let event = makeEvent(type: "worktree.acquired", payload: [
            "branch": AnyCodable("session/test-branch"),
        ])
        XCTAssertEqual(event.summary, "Branch: session/test-branch")
    }

    func testWorktreeAcquired_withoutBranch() {
        let event = makeEvent(type: "worktree.acquired")
        XCTAssertEqual(event.summary, "Branch created")
    }

    func testSessionBranch_summary() {
        let event = makeEvent(type: "session.branch")
        XCTAssertEqual(event.summary, "Branch created")
    }

    func testContextCleared_summary() {
        let event = makeEvent(type: "context.cleared")
        XCTAssertEqual(event.summary, "Context cleared")
    }

    func testErrorAgent_showsCodeAndError() {
        let event = makeEvent(type: "error.agent", payload: [
            "code": AnyCodable("TIMEOUT"),
            "error": AnyCodable("Request timed out"),
        ])
        XCTAssertEqual(event.summary, "TIMEOUT: Request timed out")
    }

    // MARK: - Skills Cleared (M6)

    /// AskUser summary promises re-activation. Must track the transformer's
    /// render mode in `Core/Events/Payloads/ExtendedPayloads.swift` and the
    /// view wiring in `Views/MessageBubble/NotificationViews.swift`.
    func testSkillsCleared_askUser_summary() {
        let event = makeEvent(type: "skills.cleared", payload: [
            "clearedSkills": AnyCodable(["a", "b"]),
            "reason": AnyCodable("compaction"),
            "mode": AnyCodable("askUser"),
        ])
        XCTAssertEqual(event.summary, "Skills cleared — re-activate? (2)")
    }

    /// ClearAll summary is informational — no re-activate suffix because
    /// the banner view does not expose chips.
    func testSkillsCleared_clearAll_summary() {
        let event = makeEvent(type: "skills.cleared", payload: [
            "clearedSkills": AnyCodable(["x", "y", "z"]),
            "reason": AnyCodable("compaction"),
            "mode": AnyCodable("clearAll"),
        ])
        XCTAssertEqual(event.summary, "Skills cleared (3)")
    }

    /// Missing `mode` surfaces a generic summary. The chat transformer drops
    /// the event entirely (strict wire contract — `mode` is required), but the
    /// summary path has no way to "drop" a list row, so it renders without the
    /// interactive "re-activate?" affordance (which would be a UX lie).
    func testSkillsCleared_missingMode_genericSummary() {
        let event = makeEvent(type: "skills.cleared", payload: [
            "clearedSkills": AnyCodable(["solo"]),
            "reason": AnyCodable("compaction"),
        ])
        XCTAssertEqual(event.summary, "Skills cleared (1)")
    }

    /// Unknown mode string produces a generic informational summary.
    /// The chat transformer drops the event entirely under this shape
    /// (see `testTransformSkillsClearedUnknownModeReturnsNil`); the
    /// summary path has no way to "drop" a list row, so it renders
    /// a neutral description without the interactive "re-activate?"
    /// affordance (which would be a UX lie).
    func testSkillsCleared_unknownMode_genericSummary() {
        let event = makeEvent(type: "skills.cleared", payload: [
            "clearedSkills": AnyCodable(["p", "q"]),
            "reason": AnyCodable("compaction"),
            "mode": AnyCodable("someFutureMode"),
        ])
        XCTAssertEqual(event.summary, "Skills cleared (2)")
    }

    /// Missing clearedSkills renders count of 0 — matches the defensive
    /// default in the summary extension. Transformer drops this event in
    /// chat; summary only surfaces in list views, so the zero-count render
    /// is acceptable.
    func testSkillsCleared_missingSkills_zeroCount() {
        let event = makeEvent(type: "skills.cleared", payload: [
            "mode": AnyCodable("askUser"),
        ])
        XCTAssertEqual(event.summary, "Skills cleared — re-activate? (0)")
    }
}
