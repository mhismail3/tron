import Foundation

// MARK: - Session Event Expanded Content

extension SessionEvent {
    /// Extended content for expanded view (Phase 3 enhanced)
    var expandedContent: String? {
        switch eventType {
        case .messageUser:
            guard let content = payload.string("content"), !content.isEmpty else { return nil }
            // Only show expanded if content is longer than the summary preview
            guard content.count > 50 else { return nil }
            return String(content.prefix(500))

        case .messageAssistant:
            var lines: [String] = []

            // Full text content from content blocks
            var fullText = ""
            if let contentArray = payload["content"]?.value as? [[String: Any]] {
                let textParts = contentArray.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                fullText = textParts.joined(separator: "\n\n")
            } else if let plain = payload.string("content") {
                fullText = plain
            }

            if !fullText.isEmpty {
                lines.append(String(fullText.prefix(500)))
            }

            // Structured metadata
            var meta: [String] = []
            if let model = payload["model"]?.value as? String {
                meta.append("Model  \(model.shortModelName)")
            }
            if let latency = payload["latency"]?.value as? Int {
                meta.append("Latency  \(formatLatency(latency))")
            }
            if let stopReason = payload["stopReason"]?.value as? String {
                let friendly: String
                switch stopReason {
                case "end_turn": friendly = "Completed"
                case "capability_invocation": friendly = "Capability invocation"
                case "max_tokens": friendly = "Max tokens"
                case "interrupted": friendly = "Interrupted"
                default: friendly = stopReason
                }
                meta.append("Stop  \(friendly)")
            }
            if payload["hasThinking"]?.value as? Bool == true {
                meta.append("Thinking  Enabled")
            }
            if let tokenRecord = payload["tokenRecord"]?.value as? [String: Any],
               let source = tokenRecord["source"] as? [String: Any],
               let input = source["rawInputTokens"] as? Int,
               let output = source["rawOutputTokens"] as? Int {
                meta.append("Input  \(TokenFormatter.format(input, style: .uppercase))")
                meta.append("Output  \(TokenFormatter.format(output, style: .uppercase))")
                if let cacheRead = source["rawCacheReadTokens"] as? Int, cacheRead > 0 {
                    meta.append("Cache ↓  \(TokenFormatter.format(cacheRead, style: .uppercase))")
                }
            }

            if !meta.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: meta)
            }

            return lines.isEmpty ? nil : lines.joined(separator: "\n")

        case .capabilityInvocationStarted:
            let name = (payload["modelPrimitiveName"]?.value as? String) ?? "unknown"
            let turn = (payload["turn"]?.value as? Int) ?? 0
            var lines = ["Capability: \(name)", "Turn: \(turn)"]

            // Format arguments if present and not too long
            if let args = payload["arguments"]?.value {
                let argsStr = formatJSON(args)
                if argsStr.count < 200 {
                    lines.append("Arguments:\n\(argsStr)")
                }
            }
            return lines.joined(separator: "\n")

        case .capabilityInvocationCompleted:
            var lines: [String] = []

            // Duration
            if let duration = payload["duration"]?.value as? Int {
                lines.append("Duration: \(duration)ms")
            }

            // Status
            let isError = (payload["isError"]?.value as? Bool) ?? false
            lines.append("Status: \(isError ? "Error" : "Success")")

            // Truncated flag
            if payload["truncated"]?.value as? Bool == true {
                lines.append("Content: Truncated")
            }

            // Content preview
            if let content = payload["content"]?.value as? String {
                let preview = String(content.prefix(200))
                lines.append("\n\(preview)")
            }
            return lines.joined(separator: "\n")

        case .errorAgent, .errorProvider, .errorCapability:
            var lines: [String] = []
            let failure = CanonicalFailurePayload.fromDetails(payload.anyCodableDict("details"))

            // Error message
            if let error = failure?.message ?? payload.string("error") {
                lines.append("Error: \(error)")
            }

            // Error code
            if let code = failure?.code ?? payload.string("code") {
                lines.append("Code: \(code)")
            }

            if let category = failure?.category ?? payload.string("category") {
                lines.append("Category: \(category)")
            }

            if let origin = failure?.origin ?? payload.string("origin") {
                lines.append("Origin: \(origin)")
            }

            // Recoverable
            if let recoverable = failure?.recoverable ?? payload.bool("recoverable") {
                lines.append("Recoverable: \(recoverable ? "Yes" : "No")")
            }

            // Retryable
            if let retryable = failure?.retryable ?? payload.bool("retryable") {
                lines.append("Retryable: \(retryable ? "Yes" : "No")")
            }

            // Retry after
            if let retryAfter = payload["retryAfter"]?.value as? Int {
                lines.append("Retry after: \(retryAfter)ms")
            }
            if let retryAfter = failure?.retryAfterMs ?? payload.int("retryAfterMs") {
                lines.append("Retry after: \(retryAfter)ms")
            }

            return lines.joined(separator: "\n")

        case .streamTurnEnd:
            var lines: [String] = []

            if let turn = payload["turn"]?.value as? Int {
                lines.append("Turn: \(turn)")
            }

            // Token usage from tokenRecord
            if let tokenRecord = payload["tokenRecord"]?.value as? [String: Any],
               let source = tokenRecord["source"] as? [String: Any] {
                if let input = source["rawInputTokens"] as? Int {
                    lines.append("Input tokens: \(TokenFormatter.format(input, style: .uppercase))")
                }
                if let output = source["rawOutputTokens"] as? Int {
                    lines.append("Output tokens: \(TokenFormatter.format(output, style: .uppercase))")
                }
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")

        default:
            return nil
        }
    }

    func formatJSON(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }
}
