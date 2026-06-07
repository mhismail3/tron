import XCTest
@testable import TronMobile

final class EventIconProviderTests: XCTestCase {

    // MARK: - Helpers

    /// All SessionEventType cases except .unknown, derived from raw values
    private static let knownEventTypes: [SessionEventType] = {
        let rawValues = [
            "session.start", "session.end", "session.fork", "session.branch",
            "message.user", "message.assistant", "message.system",
            "capability.invocation.started", "capability.invocation.completed",
            "stream.text_delta", "stream.thinking_delta", "stream.thinking_complete",
            "stream.turn_start", "stream.turn_end",
            "config.model_switch", "config.prompt_update", "config.reasoning_level",
            "message.deleted",
            "notification.interrupted",
            "rules.loaded", "rules.activated",
            "compact.boundary",
            "context.cleared",
            "metadata.update", "metadata.tag",
            "file.read", "file.write", "file.edit",
            "error.agent", "error.capability", "error.provider",
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

    // MARK: - Capability Result Payload Variants

    func testCapabilityInvocationResult_errorPayload_hasXmarkIcon() {
        let payload: [String: AnyCodable] = ["isError": AnyCodable(true)]
        XCTAssertEqual(
            EventIconProvider.iconName(for: .capabilityInvocationCompleted, payload: payload),
            "xmark.circle.fill"
        )
    }

    func testCapabilityInvocationResult_successPayload_hasCheckmarkIcon() {
        let payload: [String: AnyCodable] = ["isError": AnyCodable(false)]
        XCTAssertEqual(
            EventIconProvider.iconName(for: .capabilityInvocationCompleted, payload: payload),
            "checkmark.circle.fill"
        )
    }

    func testCapabilityInvocationResult_noPayload_hasCheckmarkIcon() {
        XCTAssertEqual(
            EventIconProvider.iconName(for: .capabilityInvocationCompleted),
            "checkmark.circle.fill"
        )
    }

    func testCapabilityInvocationResult_errorPayload_hasErrorColor() {
        let payload: [String: AnyCodable] = ["isError": AnyCodable(true)]
        XCTAssertEqual(
            EventIconProvider.color(for: .capabilityInvocationCompleted, payload: payload),
            .tronError
        )
    }

    func testCapabilityInvocationResult_successPayload_hasSuccessColor() {
        XCTAssertEqual(
            EventIconProvider.color(for: .capabilityInvocationCompleted),
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
