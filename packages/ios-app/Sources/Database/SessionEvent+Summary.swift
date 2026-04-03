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
                // Array of content blocks — extract text blocks
                let textParts = contentArray.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                text = textParts.joined(separator: " ")
            } else if let plain = payload.string("content"), !plain.isEmpty {
                text = plain
            }

            var summary = text.isEmpty
                ? "Assistant response"
                : String(text.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)

            // Add metadata indicators
            var indicators: [String] = []
            if let latency = payload.int("latency") {
                indicators.append(formatLatency(latency))
            }
            if payload.bool("hasThinking") == true {
                indicators.append("Thinking")
            }

            if !indicators.isEmpty {
                summary += " • " + indicators.joined(separator: " • ")
            }
            return summary

        case .toolCall:
            let name = payload.string("name") ?? "unknown"
            let args = payload.dict("arguments") ?? [:]
            let keyArg = extractKeyArgument(toolName: name, from: args)
            if !keyArg.isEmpty {
                return "\(name): \(keyArg)"
            }
            return name

        case .toolResult:
            let isError = payload.bool("isError") ?? false
            let duration = payload.int("duration")
            let status = isError ? "error" : "success"
            if let duration = duration {
                return "\(duration)ms • \(status)"
            }
            return status

        case .streamTurnStart:
            let turn = payload.int("turn") ?? 0
            return "Turn \(turn) started"

        case .streamTurnEnd:
            let turn = payload.int("turn") ?? 0
            if let tokenUsage = payload.dict("tokenUsage"),
               let input = tokenUsage["inputTokens"] as? Int,
               let output = tokenUsage["outputTokens"] as? Int {
                return "Turn \(turn) • \(TokenFormatter.format(input + output, style: .uppercase)) tokens"
            }
            return "Turn \(turn) ended"

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

        case .errorTool:
            let toolName = payload.string("toolName") ?? "tool"
            return "\(toolName) failed"

        case .configModelSwitch:
            let from = payload.string("previousModel")?.shortModelName ?? "?"
            let to = payload.string("newModel")?.shortModelName ??
                     payload.string("model")?.shortModelName ?? "?"
            return "\(from) → \(to)"

        case .notificationInterrupted:
            return "Session interrupted"

        case .compactBoundary:
            return "Context compacted"

        case .compactSummary:
            return "Context summarized"

        case .rulesLoaded:
            let count = payload.int("count") ?? 0
            if count > 0 {
                return "Rules loaded (\(count))"
            }
            return "Rules loaded"

        case .rulesActivated:
            let count = payload.int("totalActivated") ?? 0
            if count > 0 {
                return "Rules activated (\(count))"
            }
            return "Rules activated"

        case .contextCleared:
            return "Context cleared"

        case .skillActivated:
            let name = payload.string("name") ?? payload.string("skillName") ?? ""
            if !name.isEmpty {
                return "Skill: \(name)"
            }
            return "Skill activated"

        case .skillDeactivated:
            let name = payload.string("name") ?? payload.string("skillName") ?? ""
            if !name.isEmpty {
                return "Skill deactivated: \(name)"
            }
            return "Skill deactivated"

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

        case .worktreeAcquired:
            let branch = payload.string("branch") ?? ""
            return branch.isEmpty ? "Worktree acquired" : "Worktree: \(branch)"

        case .worktreeCommit:
            let message = payload.string("message") ?? ""
            if !message.isEmpty {
                return "Commit: \(String(message.prefix(35)))"
            }
            return "Worktree commit"

        case .worktreeReleased:
            let deleted = payload.bool("deleted") ?? false
            return deleted ? "Worktree released (deleted)" : "Worktree released"

        case .worktreeMerged:
            return "Worktree merged"

        case .worktreeRenamed:
            let newBranch = payload.string("newBranch") ?? ""
            return newBranch.isEmpty ? "Branch renamed" : "Branch: \(newBranch)"

        case .notificationProcessResult:
            let label = payload.string("label") ?? ""
            if !label.isEmpty {
                return "Process done: \(String(label.prefix(30)))"
            }
            return "Process result"

        case .processResultsConsumed:
            let count = payload.int("count") ?? 0
            return count > 0 ? "Results consumed (\(count))" : "Results consumed"

        case .unknown:
            // Format raw type into friendly name: "rules.loaded" -> "Rules loaded"
            let formatted = type
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return formatted
        }
    }

    /// Helper to extract key argument for tool display
    func extractKeyArgument(toolName: String, from args: [String: Any]) -> String {
        switch ToolKind(toolName: toolName) {
        case .read, .write, .edit:
            if let path = args["file_path"] as? String ?? args["path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case .bash:
            if let cmd = args["command"] as? String {
                return String(cmd.prefix(25))
            }
        case .search:
            if let pattern = args["pattern"] as? String {
                return "\"\(String(pattern.prefix(20)))\""
            }
        case .glob:
            if let pattern = args["pattern"] as? String {
                return pattern
            }
        default:
            break
        }
        return ""
    }

    func formatLatency(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}
