#if HOSTED_TEST
import Foundation
import TronMobileCore

/// Gateway-shaped, already classified fixture data. The real Gateway test owns
/// classification; this UI fixture exercises wire decoding and shared ChatView.
enum HostedChatErrorScenarioFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-chat-provider-errors") }
    static func error(_ id: String, mixed: Bool = false) -> JSONValue {
        let raw = mixed ? "Request timed out after 60 seconds" : "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"},\"request_id\":\"req_\(id)\"}"
        var info: [String: JSONValue] = ["message": .string(mixed ? "The connection to OpenAI timed out" : "Anthropic is overloaded"),
                                       "category": .string(mixed ? "timeout" : "overloaded")]
        if !mixed { info["type"] = .string("overloaded_error"); info["requestId"] = .string("req_\(id)") }
        return .object(["id": .string(id), "presentationId": .string(id), "timestamp": .string("2026-01-01T10:42:18Z"),
                        "kind": .string("message"), "role": .string("assistant"),
                        "content": .array([.object(["id": .string("\(id)-empty"), "ordinal": .number(0), "type": .string("text"), "text": .string("")])]),
                        "provider": .string(mixed ? "openai" : "anthropic"), "modelId": .string(mixed ? "gpt-fixture" : "claude-fixture"),
                        "stopReason": .string("error"), "errorMessage": .string(raw), "errorInfo": .object(info)])
    }
}
#endif
