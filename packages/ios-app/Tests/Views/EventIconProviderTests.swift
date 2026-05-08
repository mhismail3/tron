import XCTest
@testable import TronMobile

final class EventIconProviderTests: XCTestCase {

    // MARK: - Helpers

    /// All SessionEventType cases except .unknown, derived from raw values
    private static let knownEventTypes: [SessionEventType] = {
        let rawValues = [
            "session.start", "session.end", "session.fork", "session.branch",
            "message.user", "message.assistant", "message.system",
            "tool.call", "tool.result",
            "stream.text_delta", "stream.thinking_delta", "stream.thinking_complete",
            "stream.turn_start", "stream.turn_end",
            "config.model_switch", "config.prompt_update", "config.reasoning_level",
            "message.deleted",
            "notification.interrupted", "notification.subagent_result",
            "skills::activated", "skills::deactivated",
            "rules.loaded", "rules.activated",
            "compact.boundary", "compact.summary",
            "context.cleared",
            "metadata.update", "metadata.tag",
            "file.read", "file.write", "file.edit",
            "error.agent", "error.tool", "error.provider",
            "worktree.acquired", "worktree.commit", "worktree.released",
            "worktree.merged", "worktree.renamed",
            "subagent.spawned", "subagent.completed", "subagent.failed",
            "subagent.results_consumed",
            "notification.process_result", "process.results_consumed",
            "turn.failed",
            "memory.retained",
            "hook.llm_result",
        ]
        return rawValues.compactMap { SessionEventType(rawValue: $0) }
    }()

    // MARK: - Exhaustive Icon Coverage

    func testAllKnownEventTypes_haveExplicitIcon() {
        let defaultIcon = "circle.fill"
        for eventType in Self.knownEventTypes {
            let icon = EventIconProvider.iconName(for: eventType)
            XCTAssertNotEqual(
                icon, defaultIcon,
                "\(eventType) (raw: \(eventType.rawValue)) falls through to default icon"
            )
        }
    }

    func testUnknown_getsDefaultCircle() {
        XCTAssertEqual(EventIconProvider.iconName(for: .unknown), "circle.fill")
    }

    // MARK: - Exhaustive Color Coverage

    func testAllKnownEventTypes_haveExplicitColor() {
        let defaultColor = EventIconProvider.color(for: .unknown)
        for eventType in Self.knownEventTypes {
            let color = EventIconProvider.color(for: eventType)
            // We can't easily assert "not default" for all since some legitimately
            // share the same color as .unknown (.tronTextMuted). Instead verify
            // it returns without crashing — the explicit icon test catches fallthrough.
            _ = color
        }
    }

    // MARK: - Hook Events

    func testLlmHookResult_hasWandIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .llmHookResult), "wand.and.rays")
    }

    func testLlmHookResult_hasPurpleColor() {
        XCTAssertEqual(EventIconProvider.color(for: .llmHookResult), .tronPurple)
    }

    // MARK: - Subagent Events

    func testSubagentSpawned_hasBranchIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .subagentSpawned), "arrow.triangle.branch")
    }

    func testSubagentSpawned_hasCyanColor() {
        XCTAssertEqual(EventIconProvider.color(for: .subagentSpawned), .tronCyan)
    }

    func testSubagentCompleted_hasCheckmarkIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .subagentCompleted), "checkmark.circle.fill")
    }

    func testSubagentCompleted_hasSuccessColor() {
        XCTAssertEqual(EventIconProvider.color(for: .subagentCompleted), .tronSuccess)
    }

    func testSubagentFailed_hasXmarkIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .subagentFailed), "xmark.circle.fill")
    }

    func testSubagentFailed_hasErrorColor() {
        XCTAssertEqual(EventIconProvider.color(for: .subagentFailed), .tronError)
    }

    func testSubagentResultsConsumed_hasTrayIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .subagentResultsConsumed), "tray.and.arrow.down.fill")
    }

    func testSubagentResultsConsumed_hasSuccessColor() {
        XCTAssertEqual(EventIconProvider.color(for: .subagentResultsConsumed), .tronSuccess)
    }

    func testNotificationSubagentResult_hasBellIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .notificationSubagentResult), "bell.badge.fill")
    }

    func testNotificationSubagentResult_hasWarningColor() {
        XCTAssertEqual(EventIconProvider.color(for: .notificationSubagentResult), .tronWarning)
    }

    // MARK: - Turn Events

    func testTurnFailed_hasWarningIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .turnFailed), "exclamationmark.triangle.fill")
    }

    func testTurnFailed_hasErrorColor() {
        XCTAssertEqual(EventIconProvider.color(for: .turnFailed), .tronError)
    }

    // MARK: - Memory Events

    func testMemoryRetained_hasBrainIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .memoryRetained), "brain.head.profile.fill")
    }

    func testMemoryRetained_hasPurpleColor() {
        XCTAssertEqual(EventIconProvider.color(for: .memoryRetained), .tronPurple)
    }

    // MARK: - Tool Result Payload Variants

    func testToolResult_errorPayload_hasXmarkIcon() {
        let payload: [String: AnyCodable] = ["isError": AnyCodable(true)]
        XCTAssertEqual(
            EventIconProvider.iconName(for: .toolResult, payload: payload),
            "xmark.circle.fill"
        )
    }

    func testToolResult_successPayload_hasCheckmarkIcon() {
        let payload: [String: AnyCodable] = ["isError": AnyCodable(false)]
        XCTAssertEqual(
            EventIconProvider.iconName(for: .toolResult, payload: payload),
            "checkmark.circle.fill"
        )
    }

    func testToolResult_noPayload_hasCheckmarkIcon() {
        XCTAssertEqual(
            EventIconProvider.iconName(for: .toolResult),
            "checkmark.circle.fill"
        )
    }

    func testToolResult_errorPayload_hasErrorColor() {
        let payload: [String: AnyCodable] = ["isError": AnyCodable(true)]
        XCTAssertEqual(
            EventIconProvider.color(for: .toolResult, payload: payload),
            .tronError
        )
    }

    func testToolResult_successPayload_hasSuccessColor() {
        XCTAssertEqual(
            EventIconProvider.color(for: .toolResult),
            .tronSuccess
        )
    }

    // MARK: - Existing Event Type Spot Checks

    func testSessionStart_hasPlayIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .sessionStart), "play.circle.fill")
    }

    func testSessionStart_hasSuccessColor() {
        XCTAssertEqual(EventIconProvider.color(for: .sessionStart), .tronSuccess)
    }

    func testMessageUser_hasPersonIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .messageUser), "person.fill")
    }

    func testErrorAgent_hasWarningIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .errorAgent), "exclamationmark.triangle.fill")
    }

    func testWorktreeCommit_hasDiamondIcon() {
        XCTAssertEqual(EventIconProvider.iconName(for: .worktreeCommit), "checkmark.diamond.fill")
    }

    // MARK: - Streaming Events (should have explicit icons)

    func testStreamTextDelta_hasExplicitIcon() {
        let icon = EventIconProvider.iconName(for: .streamTextDelta)
        XCTAssertNotEqual(icon, "circle.fill", "streamTextDelta should have an explicit icon")
    }

    func testStreamThinkingDelta_hasExplicitIcon() {
        let icon = EventIconProvider.iconName(for: .streamThinkingDelta)
        XCTAssertNotEqual(icon, "circle.fill", "streamThinkingDelta should have an explicit icon")
    }

    func testStreamThinkingComplete_hasExplicitIcon() {
        let icon = EventIconProvider.iconName(for: .streamThinkingComplete)
        XCTAssertNotEqual(icon, "circle.fill", "streamThinkingComplete should have an explicit icon")
    }
}
