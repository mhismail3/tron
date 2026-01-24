import Foundation

// MARK: - Tool Payloads

/// Payload for tool.call event
/// Server: ToolCallEvent.payload
struct ToolCallPayload {
    let toolCallId: String
    let name: String
    let arguments: String  // JSON string for display
    let turn: Int

    init?(from payload: [String: AnyCodable]) {
        // toolCallId can be "toolCallId" or "id"
        guard let id = payload.string("toolCallId") ?? payload.string("id"),
              let name = payload.string("name") else {
            return nil
        }

        self.toolCallId = id
        self.name = name
        self.turn = payload.int("turn") ?? 1

        // Arguments can be dict or string
        if let argsDict = payload.dict("arguments"),
           let jsonData = try? JSONSerialization.data(withJSONObject: argsDict, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.arguments = jsonString
        } else if let argsStr = payload.string("arguments") {
            self.arguments = argsStr
        } else {
            self.arguments = "{}"
        }
    }
}

/// Payload for tool.result event
/// Server: ToolResultEvent.payload
struct ToolResultPayload {
    let toolCallId: String
    let content: String
    let isError: Bool
    let durationMs: Int
    let affectedFiles: [String]?
    let truncated: Bool?

    // Additional fields for display (may come from enrichment)
    let name: String?
    let arguments: String?

    init?(from payload: [String: AnyCodable]) {
        guard let toolCallId = payload.string("toolCallId") else {
            return nil
        }

        self.toolCallId = toolCallId
        self.content = payload.string("content") ?? ""
        self.isError = payload.bool("isError") ?? false
        self.durationMs = payload.int("duration") ?? payload.int("durationMs") ?? 0
        self.affectedFiles = payload.stringArray("affectedFiles")
        self.truncated = payload.bool("truncated")

        // Optional enrichment fields
        self.name = payload.string("name")
        if let argsDict = payload.dict("arguments"),
           let jsonData = try? JSONSerialization.data(withJSONObject: argsDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.arguments = jsonString
        } else if let argsStr = payload.string("arguments") {
            self.arguments = argsStr
        } else {
            self.arguments = nil
        }
    }
}

// MARK: - Error Payloads

/// Payload for error.agent event
/// Server: ErrorAgentEvent.payload
struct AgentErrorPayload {
    let error: String
    let code: String?
    let recoverable: Bool

    init?(from payload: [String: AnyCodable]) {
        guard let error = payload.string("error")
                ?? payload.string("message") else {
            return nil
        }

        self.error = error
        self.code = payload.string("code")
        self.recoverable = payload.bool("recoverable") ?? false
    }
}

/// Payload for error.tool event
/// Server: ErrorToolEvent.payload
struct ToolErrorPayload {
    let toolName: String
    let toolCallId: String
    let error: String
    let code: String?

    init?(from payload: [String: AnyCodable]) {
        guard let toolName = payload.string("toolName"),
              let toolCallId = payload.string("toolCallId"),
              let error = payload.string("error") else {
            return nil
        }

        self.toolName = toolName
        self.toolCallId = toolCallId
        self.error = error
        self.code = payload.string("code")
    }
}

/// Payload for error.provider event
/// Server: ErrorProviderEvent.payload
struct ProviderErrorPayload {
    let provider: String
    let error: String
    let code: String?
    let retryable: Bool
    let retryAfter: Int?

    init?(from payload: [String: AnyCodable]) {
        guard let provider = payload.string("provider"),
              let error = payload.string("error") else {
            return nil
        }

        self.provider = provider
        self.error = error
        self.code = payload.string("code")
        self.retryable = payload.bool("retryable") ?? false
        self.retryAfter = payload.int("retryAfter")
    }
}
