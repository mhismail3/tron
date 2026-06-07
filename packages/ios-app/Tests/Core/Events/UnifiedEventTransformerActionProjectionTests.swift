import XCTest
@testable import TronMobile

final class UnifiedEventTransformerActionProjectionTests: XCTestCase {
    func testReconstructedCapabilityInvocationProjectsActionSummary() {
        let events = [
            sessionEvent(type: "message.user", payload: [
                "content": AnyCodable("Check repo state")
            ], timestamp: timestamp(0), sequence: 1),
            sessionEvent(type: "capability.invocation.started", payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "invocationId": AnyCodable("action-reconstruct-1"),
                "contractId": AnyCodable("process::run"),
                "implementationId": AnyCodable("runtime.process.v1.run"),
                "functionId": AnyCodable("process::run"),
                "pluginId": AnyCodable("runtime.process"),
                "workerId": AnyCodable("process-worker"),
                "schemaDigest": AnyCodable("sha256:process"),
                "traceId": AnyCodable("trace-process"),
                "bindingDecisionId": AnyCodable("binding-process"),
                "arguments": AnyCodable([
                    "target": "process::run",
                    "intent": "Check repository state.",
                    "arguments": [
                        "command": "git status --short",
                        "executionMode": "read_only"
                    ],
                    "reason": "User asked for current repository state."
                ] as [String: Any]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(1), sequence: 2),
            sessionEvent(type: "capability.invocation.completed", payload: [
                "invocationId": AnyCodable("action-reconstruct-1"),
                "modelPrimitiveName": AnyCodable("execute"),
                "contractId": AnyCodable("process::run"),
                "implementationId": AnyCodable("runtime.process.v1.run"),
                "functionId": AnyCodable("process::run"),
                "pluginId": AnyCodable("runtime.process"),
                "workerId": AnyCodable("process-worker"),
                "schemaDigest": AnyCodable("sha256:process"),
                "traceId": AnyCodable("trace-process"),
                "bindingDecisionId": AnyCodable("binding-process"),
                "content": AnyCodable("clean"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(86),
                "details": AnyCodable([
                    "status": "ok",
                    "output": [
                        "exitCode": 0,
                        "stdout": "clean\n",
                        "timedOut": false,
                        "outputTruncated": false
                    ]
                ] as [String: Any])
            ], timestamp: timestamp(2), sequence: 3),
            sessionEvent(type: "message.assistant", payload: [
                "content": AnyCodable([
                    ["type": "capability_invocation", "id": "action-reconstruct-1", "name": "execute", "input": [
                        "command": "git status --short"
                    ]]
                ]),
                "turn": AnyCodable(1)
            ], timestamp: timestamp(3), sequence: 4)
        ]

        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        XCTAssertEqual(messages.count, 2)
        guard case .capabilityInvocation(let invocation) = messages[1].content else {
            return XCTFail("Expected capability invocation content")
        }
        XCTAssertEqual(invocation.display.primitiveTitle, "Action")
        XCTAssertEqual(invocation.display.chipTitle, "Run")
        XCTAssertEqual(invocation.display.commandText, "git status --short")
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "Executor", value: "Process Worker")))
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "Why", value: "User asked for current repository state.")))
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "Result", value: "clean")))

        let visibleProjection = [
            invocation.display.primitiveTitle,
            invocation.display.chipTitle,
            invocation.display.commandText,
            invocation.display.summaryText
        ].joined(separator: " ")
        XCTAssertFalse(visibleProjection.contains("execute"))
        XCTAssertFalse(visibleProjection.contains("first_party"))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Schema", value: "sha256:process", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Trace", value: "trace-process", isTechnical: true)))
    }

    private func timestamp(_ offsetSeconds: TimeInterval = 0) -> String {
        let date = Date().addingTimeInterval(offsetSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func sessionEvent(
        sessionId: String = "test-session",
        type: String,
        payload: [String: AnyCodable],
        timestamp: String,
        sequence: Int
    ) -> SessionEvent {
        SessionEvent(
            id: UUID().uuidString,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "/test/workspace",
            type: type,
            timestamp: timestamp,
            sequence: sequence,
            payload: augmentPayload(type: type, payload: payload)
        )
    }

    private func augmentPayload(type: String, payload: [String: AnyCodable]) -> [String: AnyCodable] {
        var augmented = payload
        if type == "message.assistant" {
            if augmented["model"] == nil { augmented["model"] = AnyCodable("claude-sonnet-4") }
            if augmented["stopReason"] == nil { augmented["stopReason"] = AnyCodable("end_turn") }
        }
        return augmented
    }
}
