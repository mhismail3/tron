import Foundation
import Testing
@testable import TronMac

@Suite("Mac Operator protocol")
struct MacOperatorProtocolTests {
    private func decode(_ value: [String: Any]) throws -> MacOperatorRequest {
        try MacOperatorProtocol.decodeRequest(
            JSONSerialization.data(withJSONObject: value)
        )
    }

    @Test("closed protocol rejects shell, script, path, and device fields")
    func rejectsGeneralPurposeControl() throws {
        let forbidden: [[String: Any]] = [
            [
                "requestId": "mac-test-1",
                "timeoutMs": 1_000,
                "action": [
                    "kind": "observe",
                    "bundleId": "com.example.app",
                    "script": "do shell script",
                ],
            ],
            [
                "requestId": "mac-test-2",
                "timeoutMs": 1_000,
                "action": ["kind": "shell", "command": ["rm", "-rf", "/"]],
            ],
            [
                "requestId": "mac-test-3",
                "timeoutMs": 1_000,
                "action": [
                    "kind": "screenshot",
                    "bundleId": "com.example.app",
                    "observationId": "observation-1",
                    "path": "/tmp/capture.png",
                ],
            ],
            [
                "requestId": "mac-test-4",
                "timeoutMs": 1_000,
                "action": ["kind": "device", "udid": "simulator"],
            ],
        ]

        for value in forbidden {
            #expect(throws: MacOperatorProtocolError.self) {
                try decode(value)
            }
        }
    }

    @Test("coordinate fallback requires exact fresh-observation shape")
    func coordinateFallbackShape() throws {
        let request = try decode([
            "requestId": "mac-test-5",
            "timeoutMs": 2_000,
            "action": [
                "kind": "coordinate_click",
                "bundleId": "com.example.app",
                "observationId": "observation-1",
                "screenshotId": "screenshot-1",
                "normalizedX": 0.25,
                "normalizedY": 0.75,
            ],
        ])

        #expect(request.action == .coordinateClick(
            bundleIdentifier: "com.example.app",
            observationID: "observation-1",
            screenshotID: "screenshot-1",
            normalizedX: 0.25,
            normalizedY: 0.75
        ))

        #expect(throws: MacOperatorProtocolError.self) {
            try decode([
                "requestId": "mac-test-6",
                "timeoutMs": 2_000,
                "action": [
                    "kind": "coordinate_click",
                    "bundleId": "com.example.app",
                    "observationId": "observation-1",
                    "normalizedX": 0.25,
                    "normalizedY": 0.75,
                ],
            ])
        }
    }

    @Test("set value is bounded and cannot target arbitrary attributes")
    func setValueBounds() throws {
        let valid = try decode([
            "requestId": "mac-test-7",
            "timeoutMs": 2_000,
            "action": [
                "kind": "set_value",
                "bundleId": "com.example.app",
                "observationId": "observation-1",
                "elementRef": "element-2",
                "text": "bounded content",
            ],
        ])
        #expect(valid.action == .setValue(
            bundleIdentifier: "com.example.app",
            observationID: "observation-1",
            elementReference: "element-2",
            text: "bounded content"
        ))

        #expect(throws: MacOperatorProtocolError.self) {
            try decode([
                "requestId": "mac-test-8",
                "timeoutMs": 2_000,
                "action": [
                    "kind": "set_value",
                    "bundleId": "com.example.app",
                    "observationId": "observation-1",
                    "elementRef": "element-2",
                    "attribute": "AXURL",
                    "text": "https://example.test",
                ],
            ])
        }
    }

    @Test("responses redact control characters and remain closed")
    func sanitizedFailureResponse() throws {
        let data = MacOperatorProtocol.failureData(
            requestID: "mac-test-9",
            code: "failed\nsecret"
        )
        let value = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(value["requestId"] as? String == "mac-test-9")
        #expect(value["ok"] as? Bool == false)
        #expect(value["error"] as? String == "failedsecret")
        #expect(Set(value.keys) == ["requestId", "ok", "error"])
    }
}
