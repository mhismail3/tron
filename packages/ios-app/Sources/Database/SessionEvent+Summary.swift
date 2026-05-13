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

            if hasThinking && stopReason == "tool_use" {
                parts.append("Thinking → tool use")
            } else if hasThinking {
                parts.append("Thinking response")
            } else if stopReason == "tool_use" {
                parts.append("Tool use")
            } else {
                parts.append("Assistant response")
            }

            if let latency = payload.int("latency") {
                parts.append(formatLatency(latency))
            }

            return parts.joined(separator: " • ")

        case .capabilityInvocationStarted:
            let name = payload.string("contractId") ??
                payload.string("functionId") ??
                payload.string("implementationId") ??
                payload.string("modelToolName") ??
                payload.string("name") ??
                "unknown"
            let displayName = formatCapabilityName(name)
            let args = payload.dict("arguments") ?? [:]
            let keyArg = extractKeyArgument(modelToolName: name, from: args)
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

        case .errorCapability:
            let modelToolName = payload.string("modelToolName") ?? "tool"
            return "\(modelToolName) failed"

        case .configModelSwitch:
            let from = payload.string("previousModel")?.shortModelName ?? "?"
            let to = payload.string("newModel")?.shortModelName ??
                     payload.string("model")?.shortModelName ?? "?"
            return "Model: \(from) → \(to)"

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

        case .skillsCleared:
            // `mode` is required by the wire contract
            // (`events/types/payloads/skill.rs` — `SkillsClearedPayload`).
            // Missing or unknown modes fall through to a generic summary so
            // the list view stays renderable, but the transformer in
            // `Core/Events/Payloads/ExtendedPayloads.swift` will drop the
            // event entirely rather than produce an interactive picker.
            let count = payload.stringArray("clearedSkills")?.count ?? 0
            switch payload.string("mode") {
            case "askUser":
                return "Skills cleared — re-activate? (\(count))"
            case "clearAll":
                return "Skills cleared (\(count))"
            default:
                return "Skills cleared (\(count))"
            }

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
            return branch.isEmpty ? "Branch created" : "Branch: \(branch)"

        case .worktreeCommit:
            let message = payload.string("message") ?? ""
            if !message.isEmpty {
                return "Commit: \(String(message.prefix(35)))"
            }
            return "Worktree commit"

        case .worktreeReleased:
            let deleted = payload.bool("deleted") ?? false
            return deleted ? "Branch deleted" : "Branch released"

        case .worktreeMerged:
            return "Branch merged"

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

        case .llmHookResult:
            let hookName = payload.string("hookName") ?? ""
            let success = (payload["success"]?.value as? Bool) ?? true
            if !hookName.isEmpty {
                return success ? "Hook: \(hookName)" : "Hook failed: \(hookName)"
            }
            return success ? "Hook completed" : "Hook failed"

        case .subagentSpawned:
            return "Subagent spawned"

        case .subagentCompleted:
            return "Subagent completed"

        case .subagentFailed:
            let error = payload.string("error") ?? ""
            if !error.isEmpty {
                return "Subagent failed: \(String(error.prefix(30)))"
            }
            return "Subagent failed"

        case .subagentResultsConsumed:
            return "Results consumed"

        case .notificationSubagentResult:
            return "Subagent result"

        case .turnFailed:
            let error = payload.string("error") ?? ""
            if !error.isEmpty {
                return "Turn failed: \(String(error.prefix(30)))"
            }
            return "Turn failed"

        case .memoryRetained:
            return "Memory retained"

        case .memoryAutoRetainTriggered:
            let interval = payload.int("intervalFired") ?? 0
            return interval > 0
                ? "Auto-retain triggered (every \(interval) turns)"
                : "Auto-retain triggered"

        case .memoryAutoRetainFailed:
            let reason = payload.string("reason") ?? ""
            return reason.isEmpty
                ? "Auto-retain failed"
                : "Auto-retain failed: \(String(reason.prefix(40)))"

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
    func extractKeyArgument(modelToolName: String, from args: [String: Any]) -> String {
        if modelToolName.hasPrefix("filesystem::") {
            if let path = args["file_path"] as? String ?? args["path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        } else if modelToolName.hasPrefix("process::") {
            if let cmd = args["command"] as? String {
                return String(cmd.prefix(25))
            }
        } else if modelToolName.contains("search") {
            if let pattern = args["pattern"] as? String {
                return "\"\(String(pattern.prefix(20)))\""
            }
        } else if modelToolName.contains("glob") {
            if let pattern = args["pattern"] as? String {
                return pattern
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
