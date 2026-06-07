import Foundation

// MARK: - Session Event Summary

extension SessionEvent {
    /// Human-readable summary of the event (Phase 3 enhanced)
    var summary: String {
        switch eventType {
        case .sessionStart:
            let model = payload.string("model") ?? "unknown"
            return "Session started • \(model.shortModelName)"

        case .sessionEnd:
            let reason = payload.string("reason") ?? "completed"
            return "Session ended (\(reason))"

        case .sessionFork:
            return "Forked session"

        case .messageUser:
            if let content = payload.string("content") {
                return String(content.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "User message"

        case .messageAssistant:
            // Extract text from content blocks or plain string
            var text = ""
            if let contentArray = payload["content"]?.value as? [[String: Any]] {
                let textParts = contentArray.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                text = textParts.joined(separator: " ")
            } else if let plain = payload.string("content"), !plain.isEmpty {
                text = plain
            }

            let preview = text.isEmpty
                ? nil
                : String(text.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)

            // Build a friendly summary
            if let preview {
                return preview
            }

            // No text content — describe what kind of response
            var parts: [String] = []
            let hasThinking = payload.bool("hasThinking") == true
            let stopReason = payload.string("stopReason")

            if hasThinking && stopReason == "capability_invocation" {
                parts.append("Thinking → capability invocation")
            } else if hasThinking {
                parts.append("Thinking response")
            } else if stopReason == "capability_invocation" {
                parts.append("Capability invocation")
            } else {
                parts.append("Assistant response")
            }

            if let latency = payload.int("latency") {
                parts.append(formatLatency(latency))
            }

            return parts.joined(separator: " • ")

        case .capabilityInvocationStarted:
            let name = payload.string("operationName") ??
                payload.string("operation") ??
                payload.string("modelPrimitiveName") ??
                "execute"
            let displayName = formatCapabilityName(name)
            let args = payload.dict("arguments") ?? [:]
            let keyArg = extractKeyArgument(from: args)
            if !keyArg.isEmpty {
                return "\(displayName): \(keyArg)"
            }
            return displayName

        case .capabilityInvocationCompleted:
            let isError = payload.bool("isError") ?? false
            let duration = payload.int("duration")
            let status = isError ? "error" : "success"
            if let duration = duration {
                return "\(duration)ms • \(status)"
            }
            return status

        case .streamTurnStart:
            guard let turn = payload.int("turn") else { return "Turn started" }
            return "Turn \(turn) started"

        case .streamTurnEnd:
            let turnLabel = payload.int("turn").map { "Turn \($0)" } ?? "Turn"
            if let tokenRecordDict = payload["tokenRecord"]?.value as? [String: Any],
               let tokenRecord = TokenRecord.from(dict: tokenRecordDict) {
                return "\(turnLabel) • \(TokenFormatter.format(tokenRecord.source.rawTotalTokens, style: .uppercase)) tokens"
            }
            return "\(turnLabel) ended"

        case .errorAgent:
            let code = payload.string("code") ?? "ERROR"
            let error = payload.string("error") ?? "Unknown error"
            return "\(code): \(String(error.prefix(30)))"

        case .errorProvider:
            let provider = payload.string("provider") ?? "provider"
            let retryable = payload.bool("retryable") ?? false
            if retryable, let delay = payload.int("retryAfter") {
                return "\(provider) • retry in \(delay)ms"
            }
            return "\(provider) error"

        case .errorCapability:
            let modelPrimitiveName = payload.string("modelPrimitiveName") ?? "capability"
            return "\(modelPrimitiveName) failed"

        case .configModelSwitch:
            let from = payload.string("previousModel")?.shortModelName ?? "?"
            let to = payload.string("newModel")?.shortModelName ??
                     payload.string("model")?.shortModelName ?? "?"
            return "Model: \(from) → \(to)"

        case .compactBoundary:
            return "Context compacted"

        case .contextCleared:
            return "Context cleared"

        case .sessionBranch:
            return "Branch created"

        case .messageSystem:
            return "System message"

        case .messageDeleted:
            return "Message deleted"

        case .configPromptUpdate:
            return "Prompt updated"

        case .configReasoningLevel:
            let level = payload.string("level") ?? payload.string("reasoningLevel") ?? ""
            if !level.isEmpty {
                return "Reasoning: \(level)"
            }
            return "Reasoning level changed"

        case .metadataUpdate:
            return "Metadata updated"

        case .metadataTag:
            let tag = payload.string("tag") ?? ""
            if !tag.isEmpty {
                return "Tag: \(tag)"
            }
            return "Tag added"

        case .fileRead:
            if let path = payload.string("path") ?? payload.string("file_path") {
                return "Read: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "File read"

        case .fileWrite:
            if let path = payload.string("path") ?? payload.string("file_path") {
                return "Write: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "File written"

        case .fileEdit:
            if let path = payload.string("path") ?? payload.string("file_path") {
                return "Edit: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "File edited"

        case .streamTextDelta, .streamThinkingDelta, .streamThinkingComplete:
            return "Streaming..."

        case .turnFailed:
            let error = payload.string("error") ?? ""
            if !error.isEmpty {
                return "Turn failed: \(String(error.prefix(30)))"
            }
            return "Turn failed"

        case .unknown:
            // Format raw type into friendly name: "foo.bar" -> "Foo Bar"
            let formatted = type
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return formatted
        }
    }

    /// Helper to extract a compact argument preview for primitive execution display.
    func extractKeyArgument(from args: [String: Any]) -> String {
        if let command = args["command"] as? String ?? args["cmd"] as? String {
            return String(command.prefix(25))
        }
        if let query = args["query"] as? String ?? args["pattern"] as? String {
            return "\"\(String(query.prefix(20)))\""
        }
        if let path = args["file_path"] as? String ?? args["path"] as? String ?? args["cwd"] as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let payload = args["payload"] as? [String: Any] {
            let nested = extractKeyArgument(from: payload)
            if !nested.isEmpty {
                return nested
            }
        }
        return ""
    }

    func formatCapabilityName(_ name: String) -> String {
        let tail = name.split(separator: "::").last.map(String.init) ?? name
        return tail
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    func formatLatency(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}
