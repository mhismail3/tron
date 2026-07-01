import XCTest
@testable import TronMobile

final class UnifiedEventTransformerMapsAndCompactionTests: UnifiedEventTransformerTestCase {
    // MARK: - Deletion Tests

    func testReconstructionSkipsDeletedEvents() {
        // Events targeted by message.deleted should be skipped in reconstruction
        let userEventId = UUID().uuidString
        let events = [
            rawEvent(id: userEventId, type: "message.user", payload: [
                "content": AnyCodable("Delete me")
            ], timestamp: timestamp(0), sequence: 1),
            rawEvent(type: "message.assistant", payload: [
                "content": AnyCodable([["type": "text", "text": "Response"]]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            // message.deleted requires targetEventId AND targetType
            rawEvent(type: "message.deleted", payload: [
                "targetEventId": AnyCodable(userEventId),
                "targetType": AnyCodable("message.user"),
                "reason": AnyCodable("user_request")
            ], timestamp: timestamp(2), sequence: 3)
        ]

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)

        // The deleted user message should not appear
        // Only assistant message should remain (text content)
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages[0].role, .assistant)
        if case .text(let text) = state.messages[0].content {
            XCTAssertEqual(text, "Response")
        }
    }

    // MARK: - buildCapabilityInvocationMaps Tests

    func testBuildCapabilityMapsCollectsCapabilityInvocationsAndResults() {
        let events = [
            rawEvent(
                id: "e1",
                type: "capability.invocation.started",
                payload: [
                    "invocationId": AnyCodable("tc1"),
                    "modelPrimitiveName": AnyCodable("execute"),
                    "arguments": AnyCodable("{\"path\":\"/test\"}"),
                    "turn": AnyCodable(1)
                ],
                sequence: 1
            ),
            rawEvent(
                id: "e2",
                type: "capability.invocation.completed",
                payload: [
                    "invocationId": AnyCodable("tc1"),
                    "content": AnyCodable("file content"),
                    "isError": AnyCodable(false),
                    "duration": AnyCodable(42)
                ],
                sequence: 2
            )
        ]

        let maps = UnifiedEventTransformer.buildCapabilityInvocationMaps(from: events)

        XCTAssertEqual(maps.startedInvocations.count, 1)
        XCTAssertEqual(maps.completedInvocations.count, 1)
        XCTAssertEqual(maps.startedInvocations["tc1"]?.name, "execute")
        XCTAssertEqual(maps.completedInvocations["tc1"]?.invocationId, "tc1")
        XCTAssertEqual(maps.completedInvocations["tc1"]?.durationMs, 42)
    }

    func testBuildCapabilityMapsEmptyEvents() {
        let maps = UnifiedEventTransformer.buildCapabilityInvocationMaps(from: [RawEvent]())

        XCTAssertTrue(maps.startedInvocations.isEmpty)
        XCTAssertTrue(maps.completedInvocations.isEmpty)
    }

    func testBuildCapabilityMapsDuplicateInvocationIdLastWins() {
        let events = [
            rawEvent(
                id: "e1",
                type: "capability.invocation.started",
                payload: [
                    "invocationId": AnyCodable("tc1"),
                    "modelPrimitiveName": AnyCodable("execute"),
                    "arguments": AnyCodable("{}"),
                    "turn": AnyCodable(1)
                ],
                sequence: 1
            ),
            rawEvent(
                id: "e2",
                type: "capability.invocation.started",
                payload: [
                    "invocationId": AnyCodable("tc1"),
                    "modelPrimitiveName": AnyCodable("execute"),
                    "arguments": AnyCodable("{}"),
                    "turn": AnyCodable(1)
                ],
                sequence: 2
            )
        ]

        let maps = UnifiedEventTransformer.buildCapabilityInvocationMaps(from: events)

        XCTAssertEqual(maps.startedInvocations.count, 1)
        XCTAssertEqual(maps.startedInvocations["tc1"]?.name, "execute")
    }

    func testBuildCapabilityMapsCapabilityResultWithoutInvocationIdSkipped() {
        // capability.invocation.completed without invocationId in payload should be gracefully skipped
        let events = [
            rawEvent(
                id: "e1",
                type: "capability.invocation.completed",
                payload: [
                    "content": AnyCodable("some result"),
                    "isError": AnyCodable(false)
                    // No invocationId!
                ],
                sequence: 1
            )
        ]

        let maps = UnifiedEventTransformer.buildCapabilityInvocationMaps(from: events)

        XCTAssertTrue(maps.completedInvocations.isEmpty)
    }

    // MARK: - compact.boundary Strict Decode Tests

    /// Happy path: valid boundary payload produces a system `.compaction`
    /// message. Mirrors the Rust `compact_boundary_minimal_payload_decodes`
    /// test to verify both sides agree on the minimal required shape.
    func testTransformCompactBoundaryMinimalPayloadProducesCompactionMessage() {
        let event = rawEvent(
            type: "compact.boundary",
            payload: [
                "originalTokens": AnyCodable(1000),
                "compactedTokens": AnyCodable(100),
                "reason": AnyCodable("manual")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNotNil(message)
        guard case .systemEvent(let systemEvent) = message?.content,
              case .compaction(let tokensBefore, let tokensAfter, let reason, _, _, _, _) = systemEvent else {
            XCTFail("Expected .compaction system event")
            return
        }
        XCTAssertEqual(tokensBefore, 1000)
        XCTAssertEqual(tokensAfter, 100)
        XCTAssertEqual(reason, "manual")
    }

    func testTransformCompactBoundaryPreservesContextControlActionRef() {
        let event = rawEvent(
            type: "compact.boundary",
            payload: [
                "originalTokens": AnyCodable(1000),
                "compactedTokens": AnyCodable(100),
                "reason": AnyCodable("manual"),
                "contextControlActionResourceId": AnyCodable("resource:context-control-action:test")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        guard case .systemEvent(let systemEvent) = message?.content else {
            XCTFail("Expected context-control-backed compaction event")
            return
        }
        XCTAssertEqual(systemEvent.contextControlActionResourceId, "resource:context-control-action:test")
    }

    func testTransformContextClearedPreservesContextControlActionRef() {
        let event = rawEvent(
            type: "context.cleared",
            payload: [
                "tokensBefore": AnyCodable(1000),
                "tokensAfter": AnyCodable(0),
                "contextControlActionResourceId": AnyCodable("resource:context-control-action:clear")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        guard case .systemEvent(let systemEvent) = message?.content else {
            XCTFail("Expected context-control-backed clear event")
            return
        }
        XCTAssertEqual(systemEvent.contextControlActionResourceId, "resource:context-control-action:clear")
    }

    /// Strict wire contract: `reason` is required. Mirrors the Rust
    /// `compact_boundary_requires_reason` test — missing field must drop
    /// the event rather than defaulting to "manual".
    func testTransformCompactBoundaryMissingReasonReturnsNil() {
        let event = rawEvent(
            type: "compact.boundary",
            payload: [
                "originalTokens": AnyCodable(1000),
                "compactedTokens": AnyCodable(100)
                // No reason — wire contract violation
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNil(message, "Missing reason must drop the event, matching Rust decoder")
    }

    /// Empty-string `reason` is rejected as equivalent to missing — a
    /// degenerate server emit should not render with an empty label in
    /// the compaction pill.
    func testTransformCompactBoundaryEmptyReasonReturnsNil() {
        let event = rawEvent(
            type: "compact.boundary",
            payload: [
                "originalTokens": AnyCodable(1000),
                "compactedTokens": AnyCodable(100),
                "reason": AnyCodable("")
            ]
        )

        let message = UnifiedEventTransformer.transformPersistedEvent(event)

        XCTAssertNil(message, "Empty reason must drop the event")
    }

    /// All four enumerated `reason` values from `CompactionReason` serde
    /// encoding (plus the import-transformer sentinel) decode successfully.
    /// Regression guard against the Rust emit path drifting from the
    /// snake_case contract.
    func testTransformCompactBoundaryAcceptsKnownReasonLabels() {
        for reason in ["manual", "threshold_exceeded", "progress_signal", "imported"] {
            let event = rawEvent(
                type: "compact.boundary",
                payload: [
                    "originalTokens": AnyCodable(1000),
                    "compactedTokens": AnyCodable(100),
                    "reason": AnyCodable(reason)
                ]
            )
            let message = UnifiedEventTransformer.transformPersistedEvent(event)
            XCTAssertNotNil(message, "\(reason) should decode")
        }
    }
}
