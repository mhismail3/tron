import XCTest
@testable import TronMobile

class UnifiedEventTransformerTestCase: XCTestCase {


    // MARK: - Helper Functions

    /// Creates a timestamp string in ISO8601 format
    func timestamp(_ offsetSeconds: TimeInterval = 0) -> String {
        let date = Date().addingTimeInterval(offsetSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func makeTokenRecordPayload(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        turn: Int = 1,
        contextWindowTokens: Int? = nil,
        newInputTokens: Int? = nil,
        previousContextBaseline: Int = 0,
        provider: String = "anthropic",
        model: String = "claude-sonnet-4",
        sessionId: String = "test-session",
        timestamp: String = "2026-01-01T00:00:00Z"
    ) -> [String: Any] {
        [
            "source": [
                "provider": provider,
                "timestamp": timestamp,
                "rawInputTokens": inputTokens,
                "rawOutputTokens": outputTokens,
                "rawCacheReadTokens": cacheReadTokens,
                "rawCachedInputTokens": cacheReadTokens,
                "rawCacheCreationTokens": cacheCreationTokens,
                "rawCacheCreation5mTokens": cacheCreationTokens,
                "rawCacheCreation1hTokens": 0,
                "rawReasoningOutputTokens": 0,
                "rawThoughtTokens": 0,
                "rawToolUsePromptTokens": 0,
                "rawTotalTokens": inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
            ],
            "computed": [
                "contextWindowTokens": contextWindowTokens ?? (inputTokens + cacheReadTokens + cacheCreationTokens),
                "newInputTokens": newInputTokens ?? inputTokens,
                "previousContextBaseline": previousContextBaseline,
                "calculationMethod": "anthropic_cache_aware"
            ],
            "meta": [
                "turn": turn,
                "sessionId": sessionId,
                "model": model,
                "contextSegmentId": "\(sessionId):\(provider):\(model)",
                "baselineResetReason": "none",
                "extractedAt": timestamp,
                "normalizedAt": timestamp
            ],
            "pricing": [
                "available": true,
                "model": model,
                "reason": NSNull(),
                "cost": [
                    "baseInputTokens": inputTokens,
                    "outputTokens": outputTokens,
                    "cacheReadTokens": cacheReadTokens,
                    "cacheWriteTokens": cacheCreationTokens,
                    "cacheWrite5mTokens": cacheCreationTokens,
                    "cacheWrite1hTokens": 0,
                    "baseInputCost": 0,
                    "outputCost": 0,
                    "cacheReadCost": 0,
                    "cacheWriteCost": 0,
                    "totalCost": 0,
                    "currency": "USD"
                ]
            ]
        ]
    }

    /// Creates a RawEvent for testing
    func rawEvent(
        id: String = UUID().uuidString,
        parentId: String? = nil,
        sessionId: String = "test-session",
        type: String,
        payload: [String: AnyCodable],
        timestamp: String? = nil,
        sequence: Int = 1
    ) -> RawEvent {
        return RawEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: "/test/workspace",
            type: type,
            timestamp: timestamp ?? self.timestamp(),
            sequence: sequence,
            payload: augmentPayload(type: type, payload: payload)
        )
    }

    /// Creates a SessionEvent for testing
    func sessionEvent(
        id: String = UUID().uuidString,
        parentId: String? = nil,
        sessionId: String = "test-session",
        type: String,
        payload: [String: AnyCodable],
        timestamp: String? = nil,
        sequence: Int = 1
    ) -> SessionEvent {
        return SessionEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: "/test/workspace",
            type: type,
            timestamp: timestamp ?? self.timestamp(),
            sequence: sequence,
            payload: augmentPayload(type: type, payload: payload)
        )
    }

    /// Inject required-but-test-irrelevant payload fields for event types that
    /// have strict schemas. Tests that care about a specific value override by
    /// setting it explicitly in the payload dict; this helper only adds fields
    /// that are absent. This mirrors the `#[serde(default)]`-free but
    /// always-emitted-by-server reality of production payloads like
    /// `message.assistant` (content / turn / model / stopReason).
    func augmentPayload(type: String, payload: [String: AnyCodable]) -> [String: AnyCodable] {
        var augmented = payload
        switch type {
        case "message.assistant":
            if augmented["turn"] == nil { augmented["turn"] = AnyCodable(1) }
            if augmented["model"] == nil { augmented["model"] = AnyCodable("claude-sonnet-4") }
            if augmented["stopReason"] == nil { augmented["stopReason"] = AnyCodable("end_turn") }
        case SessionEventType.toolInvocationStarted.rawValue:
            if augmented["toolName"] == nil {
                augmented["toolName"] = AnyCodable("process_run")
            }
        case SessionEventType.toolInvocationCompleted.rawValue:
            if augmented["toolName"] == nil {
                augmented["toolName"] = AnyCodable("process_run")
            }
        case "session.start":
            if augmented["workingDirectory"] == nil { augmented["workingDirectory"] = AnyCodable("/test/workspace") }
            if augmented["model"] == nil { augmented["model"] = AnyCodable("claude-sonnet-4") }
            if augmented["provider"] == nil { augmented["provider"] = AnyCodable("anthropic") }
        default:
            break
        }
        return augmented
    }

    /// Canonical minimal payloads for durable records rendered in the timeline.
    func renderableEventFixtures() -> [SessionEventType: [String: AnyCodable]] {
        [
            .messageUser: [
                // Production `session::reconstruct` payloads may omit `turn`.
                "content": AnyCodable("Hello from the persisted event log")
            ],
            .messageAssistant: [
                "content": AnyCodable([["type": "text", "text": "Assistant response"] as [String: Any]]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "stopReason": AnyCodable("end_turn")
            ],
            .sessionModelChanged: [
                "previousModel": AnyCodable("gpt-5.6-luna"),
                "newModel": AnyCodable("gpt-5.6-sol")
            ],
            .sessionReasoningChanged: [
                "previousLevel": AnyCodable("medium"),
                "newLevel": AnyCodable("high")
            ],
            .toolInvocationStarted: [
                "invocationId": AnyCodable("tool-fixture"),
                "toolName": AnyCodable("process_run"),
                "arguments": AnyCodable(["command": "true"]),
                "turn": AnyCodable(1)
            ],
            .toolInvocationCompleted: [
                "invocationId": AnyCodable("tool-fixture"),
                "toolName": AnyCodable("process_run"),
                "content": AnyCodable("ok"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(25)
            ],
            .compactBoundary: [
                "originalTokens": AnyCodable(10_000),
                "compactedTokens": AnyCodable(2_000),
                "reason": AnyCodable("manual")
            ],
            .turnFailed: [
                "turn": AnyCodable(1),
                "error": AnyCodable("Turn failed"),
                "recoverable": AnyCodable(true)
            ]
        ]
    }
}
