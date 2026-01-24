import Foundation

// =============================================================================
// MARK: - Unified Event Transformer
// =============================================================================

/// The single source of truth for transforming server events into ChatMessages.
///
/// This transformer handles BOTH:
/// 1. Persisted events (from `events.getHistory` RPC / SQLite)
/// 2. Streaming events (from WebSocket during live agent execution)
///
/// ## Architecture Principle
/// **Content block order is the source of truth for interleaving.**
///
/// The server sends `message.assistant` events with content blocks in exact
/// streaming order via `currentTurnContentSequence`. This preserves the interleaving
/// of text and tool calls as they appeared during streaming:
///
/// ```
/// [text: "I'll run sleep 3...", tool_use: {id: "t1"}, text: "Done!", ...]
/// ```
///
/// Tool details come from separate `tool.call` events (name, arguments, turn).
/// Tool results come from `tool.result` events. Both are combined when rendering
/// tool_use content blocks from the message.assistant.
///
/// ## Usage
/// ```swift
/// // For persisted events (history, session preview):
/// let messages = UnifiedEventTransformer.transformPersistedEvents(rawEvents)
///
/// // For streaming events (live chat):
/// if let message = UnifiedEventTransformer.transformStreamingEvent(type, data) {
///     messages.append(message)
/// }
/// ```
struct UnifiedEventTransformer {

    // =========================================================================
    // MARK: - Persisted Event Transformation
    // =========================================================================

    /// Transform an array of persisted events to ChatMessages.
    ///
    /// This is the primary method for converting server event history to
    /// displayable messages. Events are sorted by turn number (from payload),
    /// then by event type within each turn (text before tools) to preserve
    /// the logical order of Claude's responses.
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: Raw events from `events.getHistory` RPC
    /// - Returns: Array of ChatMessages in chronological order
    static func transformPersistedEvents(_ events: [RawEvent]) -> [ChatMessage] {
        // Sort by turn number, then timestamp, then sequence
        let sorted = sortEventsByTurn(events)

        // Build maps for tool calls and results
        var toolCalls: [String: ToolCallPayload] = [:]
        var toolResults: [String: ToolResultPayload] = [:]
        for event in sorted {
            if event.type == PersistedEventType.toolCall.rawValue,
               let payload = ToolCallPayload(from: event.payload) {
                toolCalls[payload.toolCallId] = payload
            }
            if event.type == PersistedEventType.toolResult.rawValue,
               let payload = ToolResultPayload(from: event.payload) {
                toolResults[payload.toolCallId] = payload
            }
        }

        // Transform events, processing message.assistant content blocks in order
        var messages: [ChatMessage] = []
        for event in sorted {
            // Skip tool.call and tool.result - they're processed via message.assistant content blocks
            if event.type == PersistedEventType.toolCall.rawValue ||
               event.type == PersistedEventType.toolResult.rawValue {
                continue
            }

            // message.assistant: process content blocks in order (preserves interleaving)
            if event.type == PersistedEventType.messageAssistant.rawValue {
                let interleaved = transformAssistantMessageInterleaved(
                    event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults
                )
                messages.append(contentsOf: interleaved)
            } else {
                if let msg = transformPersistedEvent(event) {
                    messages.append(msg)
                }
            }
        }

        return messages
    }

    /// Transform an array of SessionEvents (from EventDatabase) to ChatMessages.
    ///
    /// Overload that accepts SessionEvent from the local SQLite database.
    /// SessionEvent includes additional fields like parentId, sessionId, etc.
    /// but uses the same core fields (type, timestamp, payload) for transformation.
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: SessionEvents from EventDatabase
    /// - Returns: Array of ChatMessages in chronological order
    static func transformPersistedEvents(_ events: [SessionEvent]) -> [ChatMessage] {
        // Sort by turn number, then timestamp, then sequence
        let sorted = sortEventsByTurn(events)

        // Build maps for tool calls and results
        var toolCalls: [String: ToolCallPayload] = [:]
        var toolResults: [String: ToolResultPayload] = [:]
        for event in sorted {
            if event.type == PersistedEventType.toolCall.rawValue,
               let payload = ToolCallPayload(from: event.payload) {
                toolCalls[payload.toolCallId] = payload
            }
            if event.type == PersistedEventType.toolResult.rawValue,
               let payload = ToolResultPayload(from: event.payload) {
                toolResults[payload.toolCallId] = payload
            }
        }

        // Transform events, processing message.assistant content blocks in order
        var messages: [ChatMessage] = []
        for event in sorted {
            // Skip tool.call and tool.result - they're processed via message.assistant content blocks
            if event.type == PersistedEventType.toolCall.rawValue ||
               event.type == PersistedEventType.toolResult.rawValue {
                continue
            }

            // message.assistant: process content blocks in order (preserves interleaving)
            if event.type == PersistedEventType.messageAssistant.rawValue {
                let interleaved = transformAssistantMessageInterleaved(
                    event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults
                )
                messages.append(contentsOf: interleaved)
            } else {
                if let msg = transformPersistedEvent(type: event.type, timestamp: event.timestamp, payload: event.payload) {
                    messages.append(msg)
                }
            }
        }

        return messages
    }

    /// Transform a single SessionEvent (from EventDatabase) to a ChatMessage.
    static func transformPersistedEvent(_ event: SessionEvent) -> ChatMessage? {
        transformPersistedEvent(type: event.type, timestamp: event.timestamp, payload: event.payload)
    }

    /// Internal helper: transform by extracting common fields.
    private static func transformPersistedEvent(
        type: String,
        timestamp: String,
        payload: [String: AnyCodable]
    ) -> ChatMessage? {
        guard let eventType = PersistedEventType(rawValue: type) else {
            logger.warning("Unknown persisted event type: \(type)", category: .events)
            return nil
        }

        // Skip events that don't render as chat messages
        guard eventType.rendersAsChatMessage else { return nil }

        let ts = parseTimestamp(timestamp)

        switch eventType {
        case .messageUser:
            return transformUserMessage(payload, timestamp: ts)
        case .messageAssistant:
            return transformAssistantMessage(payload, timestamp: ts)
        case .messageSystem:
            return transformSystemMessage(payload, timestamp: ts)
        case .toolCall:
            return transformToolCall(payload, timestamp: ts)
        case .toolResult:
            return transformToolResult(payload, timestamp: ts)
        case .notificationInterrupted:
            return transformInterrupted(payload, timestamp: ts)
        case .configModelSwitch:
            return transformModelSwitch(payload, timestamp: ts)
        case .configReasoningLevel:
            return transformReasoningLevelChange(payload, timestamp: ts)
        case .errorAgent:
            return transformAgentError(payload, timestamp: ts)
        case .errorTool:
            return transformToolError(payload, timestamp: ts)
        case .errorProvider:
            return transformProviderError(payload, timestamp: ts)
        case .contextCleared:
            return transformContextCleared(payload, timestamp: ts)
        case .compactBoundary:
            return transformCompactBoundary(payload, timestamp: ts)
        case .skillRemoved:
            return transformSkillRemoved(payload, timestamp: ts)
        case .rulesLoaded:
            return transformRulesLoaded(payload, timestamp: ts)
        case .streamThinkingComplete:
            return transformThinkingComplete(payload, timestamp: ts)
        default:
            return nil
        }
    }

    /// Transform a single persisted event (RawEvent from RPC) to a ChatMessage.
    ///
    /// Returns nil for events that don't render as messages (metadata events,
    /// streaming deltas, etc.)
    ///
    /// - Parameter event: A raw event from the server
    /// - Returns: ChatMessage if this event should be displayed, nil otherwise
    static func transformPersistedEvent(_ event: RawEvent) -> ChatMessage? {
        transformPersistedEvent(type: event.type, timestamp: event.timestamp, payload: event.payload)
    }

    // =========================================================================
    // MARK: - Persisted Event Handlers
    // =========================================================================

    private static func transformUserMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = UserMessagePayload(from: payload) else { return nil }

        // Skip tool_result context messages - they're LLM conversation context,
        // not displayable user messages. Tool results are displayed via tool.result events.
        if parsed.isToolResultContext {
            return nil
        }

        // AskUserQuestion answer prompts - render as a chip instead of full text
        if parsed.content.contains("[Answers to your questions]") {
            // Count the questions by parsing the message (count ** markers)
            let questionCount = parsed.content.components(separatedBy: "\n**").count - 1
            return ChatMessage(
                role: .user,
                content: .answeredQuestions(questionCount: max(1, questionCount)),
                timestamp: timestamp
            )
        }

        // Skip empty user messages (unless they have attachments, skills, or spells)
        guard !parsed.content.isEmpty || parsed.attachments != nil || parsed.skills != nil || parsed.spells != nil else { return nil }

        return ChatMessage(
            role: .user,
            content: .text(parsed.content),
            timestamp: timestamp,
            attachments: parsed.attachments,
            skills: parsed.skills,
            spells: parsed.spells
        )
    }

    private static func transformAssistantMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let parsed = AssistantMessagePayload(from: payload)

        // CRITICAL: Only extract TEXT from assistant messages
        // Tool blocks are handled by tool.call/tool.result events
        guard let text = parsed.textContent, !text.isEmpty else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .text(text),
            timestamp: timestamp,
            tokenUsage: parsed.tokenUsage,
            model: parsed.model,
            latencyMs: parsed.latencyMs,
            turnNumber: parsed.turn,
            hasThinking: parsed.hasThinking,
            stopReason: parsed.stopReason?.rawValue
        )
    }

    /// Transform a message.assistant event's content blocks into ordered ChatMessages.
    ///
    /// This is the key function for preserving interleaved text and tool calls.
    /// The server sends content blocks in exact streaming order via `currentTurnContentSequence`.
    /// We process each block in order, creating separate messages for text and tool use.
    ///
    /// Special handling for AskUserQuestion:
    /// - Detected by tool name and converted to `MessageContent.askUserQuestion`
    /// - Text AFTER AskUserQuestion is skipped (question should be final entry)
    /// - Status (pending/answered/superseded) detected from subsequent events
    ///
    /// - Parameters:
    ///   - payload: The message.assistant event payload
    ///   - timestamp: Event timestamp
    ///   - toolCalls: Map of toolCallId -> ToolCallPayload for tool details
    ///   - toolResults: Map of toolCallId -> ToolResultPayload for results
    ///   - allEvents: Optional array of all events for AskUserQuestion status detection
    /// - Returns: Array of ChatMessages in content block order
    private static func transformAssistantMessageInterleaved(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        toolCalls: [String: ToolCallPayload],
        toolResults: [String: ToolResultPayload],
        allEvents: [RawEvent]? = nil
    ) -> [ChatMessage] {
        let parsed = AssistantMessagePayload(from: payload)
        guard let blocks = parsed.contentBlocks else { return [] }

        // Token usage from message.assistant payload (required)
        let effectiveTokenUsage = parsed.tokenUsage

        // Incremental tokens for stats line display - from normalizedUsage on message.assistant
        let effectiveIncrementalTokens: TokenUsage?
        if let normalized = parsed.normalizedUsage {
            effectiveIncrementalTokens = TokenUsage(
                inputTokens: normalized.newInputTokens,
                outputTokens: normalized.outputTokens,
                cacheReadTokens: normalized.cacheReadTokens,
                cacheCreationTokens: normalized.cacheCreationTokens
            )
            logger.debug("[TOKEN-FLOW] iOS: message.assistant reconstruction", category: .events)
            logger.debug("  turn=\(parsed.turn ?? -1), blocks=\(blocks.count)", category: .events)
            logger.debug("  normalizedUsage: newInput=\(normalized.newInputTokens), contextWindow=\(normalized.contextWindowTokens), output=\(normalized.outputTokens)", category: .events)
        } else {
            // Server MUST provide normalizedUsage - stats will be missing
            logger.warning("[TOKEN-FLOW] iOS: message.assistant MISSING normalizedUsage (turn=\(parsed.turn ?? -1))", category: .events)
            effectiveIncrementalTokens = nil
        }

        var messages: [ChatMessage] = []
        var sawAskUserQuestion = false  // Track if AskUserQuestion was seen

        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }

            // If AskUserQuestion was already processed, skip subsequent text blocks
            if sawAskUserQuestion && blockType == "text" {
                continue
            }

            if blockType == "thinking", let thinkingText = block["thinking"] as? String, !thinkingText.isEmpty {
                // Create thinking message - appears before text response
                // Store full content; ThinkingContentView computes its own preview
                messages.append(ChatMessage(
                    role: .assistant,
                    content: .thinking(visible: thinkingText, isExpanded: false, isStreaming: false),
                    timestamp: timestamp
                ))
            } else if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                // Create text message - only text responses show token stats
                // incrementalTokens from normalizedUsage (newInputTokens) for consistent stats line display
                messages.append(ChatMessage(
                    role: .assistant,
                    content: .text(text),
                    timestamp: timestamp,
                    tokenUsage: effectiveTokenUsage,
                    incrementalTokens: effectiveIncrementalTokens,
                    model: parsed.model,
                    latencyMs: messages.isEmpty ? parsed.latencyMs : nil,
                    turnNumber: parsed.turn,
                    hasThinking: messages.isEmpty ? parsed.hasThinking : nil,
                    stopReason: messages.isEmpty ? parsed.stopReason?.rawValue : nil
                ))
            } else if blockType == "tool_use", let toolUseId = block["id"] as? String {
                // Find matching tool.call for full details, fall back to content block info
                let toolCall = toolCalls[toolUseId]
                let result = toolResults[toolUseId]

                // Use tool.call details if available, otherwise fall back to content block
                let toolName = toolCall?.name ?? (block["name"] as? String) ?? "Unknown"

                // Check if this is AskUserQuestion - handle specially
                if toolName == "AskUserQuestion" {
                    sawAskUserQuestion = true
                    if let askUserMessage = transformAskUserQuestionToolUse(
                        toolUseId: toolUseId,
                        toolCall: toolCall,
                        contentBlock: block,
                        timestamp: timestamp,
                        tokenUsage: nil,  // Stats only shown on text messages
                        model: nil,
                        turn: parsed.turn,
                        allEvents: allEvents
                    ) {
                        messages.append(askUserMessage)
                    }
                    continue
                }

                // Regular tool handling
                let turn = toolCall?.turn ?? parsed.turn

                // Determine status based on result
                let status: ToolStatus
                if let result = result {
                    status = result.isError ? .error : .success
                } else {
                    status = .running
                }

                // Format result content - show "(no output)" if result is empty
                let resultContent: String?
                if let result = result {
                    resultContent = result.content.isEmpty ? "(no output)" : result.content
                } else {
                    resultContent = nil
                }

                // Arguments: use tool.call string if available, else serialize content block input
                let arguments: String
                if let toolCallArgs = toolCall?.arguments {
                    arguments = toolCallArgs
                } else if let inputDict = block["input"] as? [String: Any],
                          let jsonData = try? JSONSerialization.data(withJSONObject: inputDict, options: [.sortedKeys]),
                          let jsonString = String(data: jsonData, encoding: .utf8) {
                    arguments = jsonString
                } else {
                    arguments = "{}"
                }

                // Tool messages don't show stats - only text responses do
                messages.append(ChatMessage(
                    role: .assistant,
                    content: .toolUse(ToolUseData(
                        toolName: toolName,
                        toolCallId: toolUseId,
                        arguments: arguments,
                        status: status,
                        result: resultContent,
                        durationMs: result?.durationMs
                    )),
                    timestamp: timestamp,
                    tokenUsage: nil,
                    model: nil,
                    latencyMs: nil,
                    turnNumber: turn,
                    hasThinking: nil,
                    stopReason: nil
                ))
            }
            // Other block types (redacted, etc.) are skipped
        }

        return messages
    }

    /// Transform an AskUserQuestion tool_use content block into proper AskUserQuestionToolData.
    ///
    /// This ensures AskUserQuestion tool calls render as interactive question chips
    /// instead of generic tool results on session restoration.
    private static func transformAskUserQuestionToolUse(
        toolUseId: String,
        toolCall: ToolCallPayload?,
        contentBlock: [String: Any],
        timestamp: Date,
        tokenUsage: TokenUsage?,
        model: String?,
        turn: Int,
        allEvents: [RawEvent]?
    ) -> ChatMessage? {
        // Parse the params from arguments
        let argumentsJson: String
        if let toolCallArgs = toolCall?.arguments {
            argumentsJson = toolCallArgs
        } else if let inputDict = contentBlock["input"] as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: inputDict),
                  let jsonString = String(data: jsonData, encoding: .utf8) {
            argumentsJson = jsonString
        } else {
            logger.warning("AskUserQuestion: Could not extract arguments", category: .events)
            return nil
        }

        guard let paramsData = argumentsJson.data(using: .utf8),
              let params = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData) else {
            logger.warning("AskUserQuestion: Could not decode params from arguments", category: .events)
            return nil
        }

        // Determine status and parse answers from subsequent events
        let detection: AskUserQuestionDetectionResult
        if let events = allEvents {
            detection = detectAskUserQuestionStatusAndAnswers(toolUseId: toolUseId, params: params, events: events)
        } else {
            detection = AskUserQuestionDetectionResult(status: .pending, answers: [:], answerMessageContent: nil)
        }

        // Build result if answered
        let result: AskUserQuestionResult?
        if detection.status == .answered && !detection.answers.isEmpty {
            result = AskUserQuestionResult(
                answers: Array(detection.answers.values),
                complete: true,
                submittedAt: ""  // Not available from persisted data
            )
        } else {
            result = nil
        }

        let toolData = AskUserQuestionToolData(
            toolCallId: toolUseId,
            params: params,
            answers: detection.answers,
            status: detection.status,
            result: result
        )

        return ChatMessage(
            role: .assistant,
            content: .askUserQuestion(toolData),
            timestamp: timestamp,
            tokenUsage: tokenUsage,
            model: model,
            turnNumber: turn
        )
    }

    /// Result of detecting AskUserQuestion status - includes both status and parsed answers
    private struct AskUserQuestionDetectionResult {
        let status: AskUserQuestionStatus
        let answers: [String: AskUserQuestionAnswer]
        let answerMessageContent: String?
    }

    /// Detect if an AskUserQuestion was answered or superseded, and extract answers if available.
    private static func detectAskUserQuestionStatusAndAnswers(
        toolUseId: String,
        params: AskUserQuestionParams,
        events: [RawEvent]
    ) -> AskUserQuestionDetectionResult {
        // Find the tool.call event index for this toolUseId
        guard let toolCallIndex = events.firstIndex(where: {
            $0.type == PersistedEventType.toolCall.rawValue &&
            (ToolCallPayload(from: $0.payload)?.toolCallId == toolUseId)
        }) else {
            // No tool.call event found - assume pending
            return AskUserQuestionDetectionResult(status: .pending, answers: [:], answerMessageContent: nil)
        }

        // Look at subsequent events for user messages
        for i in (toolCallIndex + 1)..<events.count {
            let event = events[i]
            if event.type == PersistedEventType.messageUser.rawValue {
                guard let content = event.payload["content"]?.value as? String else { continue }
                if content.contains("[Answers to your questions]") {
                    // Parse the answers from the message content
                    let answers = parseAnswersFromMessage(content: content, params: params)
                    return AskUserQuestionDetectionResult(status: .answered, answers: answers, answerMessageContent: content)
                } else {
                    // User sent a different message - question was skipped
                    return AskUserQuestionDetectionResult(status: .superseded, answers: [:], answerMessageContent: nil)
                }
            }
        }

        // No user message after - still pending
        return AskUserQuestionDetectionResult(status: .pending, answers: [:], answerMessageContent: nil)
    }

    /// Overload for SessionEvent array (from SQLite database)
    private static func detectAskUserQuestionStatusAndAnswers(
        toolUseId: String,
        params: AskUserQuestionParams,
        events: [SessionEvent]
    ) -> AskUserQuestionDetectionResult {
        // Find the tool.call event index for this toolUseId
        guard let toolCallIndex = events.firstIndex(where: {
            $0.type == PersistedEventType.toolCall.rawValue &&
            (ToolCallPayload(from: $0.payload)?.toolCallId == toolUseId)
        }) else {
            // No tool.call event found - assume pending
            return AskUserQuestionDetectionResult(status: .pending, answers: [:], answerMessageContent: nil)
        }

        // Look at subsequent events for user messages
        for i in (toolCallIndex + 1)..<events.count {
            let event = events[i]
            if event.type == PersistedEventType.messageUser.rawValue {
                guard let content = event.payload["content"]?.value as? String else { continue }
                if content.contains("[Answers to your questions]") {
                    // Parse the answers from the message content
                    let answers = parseAnswersFromMessage(content: content, params: params)
                    return AskUserQuestionDetectionResult(status: .answered, answers: answers, answerMessageContent: content)
                } else {
                    // User sent a different message - question was skipped
                    return AskUserQuestionDetectionResult(status: .superseded, answers: [:], answerMessageContent: nil)
                }
            }
        }

        // No user message after - still pending
        return AskUserQuestionDetectionResult(status: .pending, answers: [:], answerMessageContent: nil)
    }

    /// Parse answers from the formatted answer message content.
    /// Format:
    /// ```
    /// [Answers to your questions]
    ///
    /// **Question text?**
    /// Answer: SelectedValue1, SelectedValue2
    ///
    /// **Question text 2?**
    /// Answer: [Other] custom input
    /// ```
    private static func parseAnswersFromMessage(
        content: String,
        params: AskUserQuestionParams
    ) -> [String: AskUserQuestionAnswer] {
        var answers: [String: AskUserQuestionAnswer] = [:]

        // Split by question markers (lines starting with **)
        let lines = content.components(separatedBy: "\n")
        var currentQuestionText: String?
        var currentAnswerLine: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check for question line: **Question text?**
            if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") {
                // Save previous question/answer pair if exists
                if let questionText = currentQuestionText, let answerLine = currentAnswerLine {
                    if let answer = parseAnswerForQuestion(questionText: questionText, answerLine: answerLine, params: params) {
                        answers[answer.questionId] = answer
                    }
                }

                // Extract new question text (remove ** markers)
                currentQuestionText = String(trimmed.dropFirst(2).dropLast(2))
                currentAnswerLine = nil
            }
            // Check for answer line: Answer: ...
            else if trimmed.hasPrefix("Answer:") {
                currentAnswerLine = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Don't forget the last question/answer pair
        if let questionText = currentQuestionText, let answerLine = currentAnswerLine {
            if let answer = parseAnswerForQuestion(questionText: questionText, answerLine: answerLine, params: params) {
                answers[answer.questionId] = answer
            }
        }

        return answers
    }

    /// Parse a single answer line and match it to a question from params
    private static func parseAnswerForQuestion(
        questionText: String,
        answerLine: String,
        params: AskUserQuestionParams
    ) -> AskUserQuestionAnswer? {
        // Find the matching question by text
        guard let question = params.questions.first(where: { $0.question == questionText }) else {
            logger.verbose("Could not find question matching: \(questionText)", category: .events)
            return nil
        }

        // Check for [Other] prefix
        if answerLine.hasPrefix("[Other]") {
            let otherValue = String(answerLine.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            return AskUserQuestionAnswer(
                questionId: question.id,
                selectedValues: [],
                otherValue: otherValue.isEmpty ? nil : otherValue
            )
        }

        // Check for "(no selection)"
        if answerLine == "(no selection)" {
            return AskUserQuestionAnswer(
                questionId: question.id,
                selectedValues: [],
                otherValue: nil
            )
        }

        // Parse comma-separated values
        let selectedValues = answerLine.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        return AskUserQuestionAnswer(
            questionId: question.id,
            selectedValues: selectedValues,
            otherValue: nil
        )
    }

    // MARK: - SessionEvent Overloads (for SQLite database events)

    /// Overload of transformAssistantMessageInterleaved for SessionEvent array
    private static func transformAssistantMessageInterleaved(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        toolCalls: [String: ToolCallPayload],
        toolResults: [String: ToolResultPayload],
        allEvents: [SessionEvent]?
    ) -> [ChatMessage] {
        let parsed = AssistantMessagePayload(from: payload)
        guard let blocks = parsed.contentBlocks else { return [] }

        var messages: [ChatMessage] = []
        var sawAskUserQuestion = false

        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }

            if sawAskUserQuestion && blockType == "text" {
                continue
            }

            if blockType == "thinking", let thinkingText = block["thinking"] as? String, !thinkingText.isEmpty {
                // Create thinking message - appears before text response
                // Store full content; ThinkingContentView computes its own preview
                messages.append(ChatMessage(
                    role: .assistant,
                    content: .thinking(visible: thinkingText, isExpanded: false, isStreaming: false),
                    timestamp: timestamp
                ))
            } else if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: .text(text),
                    timestamp: timestamp,
                    tokenUsage: messages.isEmpty ? parsed.tokenUsage : nil,
                    model: messages.isEmpty ? parsed.model : nil,
                    latencyMs: messages.isEmpty ? parsed.latencyMs : nil,
                    turnNumber: parsed.turn,
                    hasThinking: messages.isEmpty ? parsed.hasThinking : nil,
                    stopReason: messages.isEmpty ? parsed.stopReason?.rawValue : nil
                ))
            } else if blockType == "tool_use", let toolUseId = block["id"] as? String {
                let toolCall = toolCalls[toolUseId]
                let result = toolResults[toolUseId]
                let toolName = toolCall?.name ?? (block["name"] as? String) ?? "Unknown"

                if toolName == "AskUserQuestion" {
                    sawAskUserQuestion = true
                    if let askUserMessage = transformAskUserQuestionToolUse(
                        toolUseId: toolUseId,
                        toolCall: toolCall,
                        contentBlock: block,
                        timestamp: timestamp,
                        tokenUsage: messages.isEmpty ? parsed.tokenUsage : nil,
                        model: messages.isEmpty ? parsed.model : nil,
                        turn: parsed.turn,
                        allSessionEvents: allEvents
                    ) {
                        messages.append(askUserMessage)
                    }
                    continue
                }

                let turn = toolCall?.turn ?? parsed.turn
                let status: ToolStatus
                if let result = result {
                    status = result.isError ? .error : .success
                } else {
                    status = .running
                }

                let resultContent: String?
                if let result = result {
                    resultContent = result.content.isEmpty ? "(no output)" : result.content
                } else {
                    resultContent = nil
                }

                let arguments: String
                if let toolCallArgs = toolCall?.arguments {
                    arguments = toolCallArgs
                } else if let inputDict = block["input"] as? [String: Any],
                          let jsonData = try? JSONSerialization.data(withJSONObject: inputDict, options: [.sortedKeys]),
                          let jsonString = String(data: jsonData, encoding: .utf8) {
                    arguments = jsonString
                } else {
                    arguments = "{}"
                }

                messages.append(ChatMessage(
                    role: .assistant,
                    content: .toolUse(ToolUseData(
                        toolName: toolName,
                        toolCallId: toolUseId,
                        arguments: arguments,
                        status: status,
                        result: resultContent,
                        durationMs: result?.durationMs
                    )),
                    timestamp: timestamp,
                    tokenUsage: messages.isEmpty ? parsed.tokenUsage : nil,
                    model: messages.isEmpty ? parsed.model : nil,
                    latencyMs: messages.isEmpty ? parsed.latencyMs : nil,
                    turnNumber: turn,
                    hasThinking: messages.isEmpty ? parsed.hasThinking : nil,
                    stopReason: messages.isEmpty ? parsed.stopReason?.rawValue : nil
                ))
            }
        }

        return messages
    }

    /// Overload of transformAskUserQuestionToolUse for SessionEvent array
    private static func transformAskUserQuestionToolUse(
        toolUseId: String,
        toolCall: ToolCallPayload?,
        contentBlock: [String: Any],
        timestamp: Date,
        tokenUsage: TokenUsage?,
        model: String?,
        turn: Int,
        allSessionEvents: [SessionEvent]?
    ) -> ChatMessage? {
        let argumentsJson: String
        if let toolCallArgs = toolCall?.arguments {
            argumentsJson = toolCallArgs
        } else if let inputDict = contentBlock["input"] as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: inputDict),
                  let jsonString = String(data: jsonData, encoding: .utf8) {
            argumentsJson = jsonString
        } else {
            logger.warning("AskUserQuestion: Could not extract arguments", category: .events)
            return nil
        }

        guard let paramsData = argumentsJson.data(using: .utf8),
              let params = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData) else {
            logger.warning("AskUserQuestion: Could not decode params from arguments", category: .events)
            return nil
        }

        // Determine status and parse answers from subsequent events
        let detection: AskUserQuestionDetectionResult
        if let events = allSessionEvents {
            detection = detectAskUserQuestionStatusAndAnswers(toolUseId: toolUseId, params: params, events: events)
        } else {
            detection = AskUserQuestionDetectionResult(status: .pending, answers: [:], answerMessageContent: nil)
        }

        // Build result if answered
        let result: AskUserQuestionResult?
        if detection.status == .answered && !detection.answers.isEmpty {
            result = AskUserQuestionResult(
                answers: Array(detection.answers.values),
                complete: true,
                submittedAt: ""  // Not available from persisted data
            )
        } else {
            result = nil
        }

        let toolData = AskUserQuestionToolData(
            toolCallId: toolUseId,
            params: params,
            answers: detection.answers,
            status: detection.status,
            result: result
        )

        return ChatMessage(
            role: .assistant,
            content: .askUserQuestion(toolData),
            timestamp: timestamp,
            tokenUsage: tokenUsage,
            model: model,
            turnNumber: turn
        )
    }

    private static func transformSystemMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = SystemMessagePayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .text(parsed.content),
            timestamp: timestamp
        )
    }

    private static func transformToolCall(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolCallPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: parsed.name,
                toolCallId: parsed.toolCallId,
                arguments: parsed.arguments,
                status: .success  // Will be updated by tool.result
            )),
            timestamp: timestamp,
            turnNumber: parsed.turn
        )
    }


    private static func transformToolResult(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolResultPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .toolResult,
            content: .toolResult(ToolResultData(
                toolCallId: parsed.toolCallId,
                content: parsed.content,
                isError: parsed.isError,
                toolName: parsed.name,
                arguments: parsed.arguments,
                durationMs: parsed.durationMs
            )),
            timestamp: timestamp
        )
    }

    private static func transformInterrupted(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        return ChatMessage(
            role: .system,
            content: .interrupted,
            timestamp: timestamp
        )
    }

    private static func transformModelSwitch(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ModelSwitchPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .modelChange(
                from: formatModelDisplayName(parsed.previousModel),
                to: formatModelDisplayName(parsed.newModel)
            ),
            timestamp: timestamp
        )
    }

    private static func transformReasoningLevelChange(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let parsed = ReasoningLevelPayload(from: payload)

        // Need both previous and new levels to show a meaningful notification
        guard let previousLevel = parsed.previousLevel,
              let newLevel = parsed.newLevel else { return nil }

        return ChatMessage(
            role: .system,
            content: .reasoningLevelChange(
                from: previousLevel.capitalized,
                to: newLevel.capitalized
            ),
            timestamp: timestamp
        )
    }

    private static func transformAgentError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = AgentErrorPayload(from: payload) else { return nil }

        let errorText = parsed.code != nil
            ? "[\(parsed.code!)] \(parsed.error)"
            : parsed.error

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    private static func transformToolError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolErrorPayload(from: payload) else { return nil }

        var errorText = "Tool '\(parsed.toolName)' failed: \(parsed.error)"
        if let code = parsed.code {
            errorText = "[\(code)] \(errorText)"
        }

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    private static func transformProviderError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ProviderErrorPayload(from: payload) else { return nil }

        var errorText = "\(parsed.provider) error: \(parsed.error)"
        if let code = parsed.code {
            errorText = "[\(code)] \(errorText)"
        }
        if parsed.retryable, let retryAfter = parsed.retryAfter {
            errorText += " (retrying in \(retryAfter)ms)"
        }

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    private static func transformContextCleared(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ContextClearedPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .contextCleared(
                tokensBefore: parsed.tokensBefore,
                tokensAfter: parsed.tokensAfter
            ),
            timestamp: timestamp
        )
    }

    private static func transformCompactBoundary(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = CompactBoundaryPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .compaction(
                tokensBefore: parsed.originalTokens,
                tokensAfter: parsed.compactedTokens,
                reason: parsed.reason,
                summary: parsed.summary
            ),
            timestamp: timestamp
        )
    }

    private static func transformSkillRemoved(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let skillName = payload["skillName"]?.value as? String else {
            logger.warning("skill.removed event missing skillName in payload", category: .events)
            return nil
        }

        return ChatMessage(
            role: .system,
            content: .skillRemoved(skillName: skillName),
            timestamp: timestamp
        )
    }

    private static func transformRulesLoaded(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let totalFiles = payload["totalFiles"]?.value as? Int else {
            logger.warning("rules.loaded event missing totalFiles in payload", category: .events)
            return nil
        }

        // Only show notification if there are rules files
        guard totalFiles > 0 else { return nil }

        return ChatMessage(
            role: .system,
            content: .rulesLoaded(count: totalFiles),
            timestamp: timestamp
        )
    }

    private static func transformThinkingComplete(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let parsed = ThinkingCompletePayload(from: payload)

        // Use preview for initial display; full content loaded lazily on tap
        let displayText = parsed.preview.isEmpty ? parsed.content : parsed.preview

        return ChatMessage(
            role: .assistant,
            content: .thinking(visible: displayText, isExpanded: false, isStreaming: false),
            timestamp: timestamp
        )
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================

    /// Sort events by sequence number (primary), which is the authoritative order from the database.
    ///
    /// Sequence number is always reliable and represents the actual event order.
    /// Thinking blocks within message.assistant content are already in correct order
    /// and are handled by transformAssistantMessageInterleaved.
    private static func sortEventsByTurn(_ events: [RawEvent]) -> [RawEvent] {
        events.sorted { a, b in
            // Primary sort: by sequence number (authoritative order)
            if a.sequence != b.sequence {
                return a.sequence < b.sequence
            }

            // Secondary sort: by timestamp (for events with same sequence, if any)
            let tsA = parseTimestamp(a.timestamp)
            let tsB = parseTimestamp(b.timestamp)
            return tsA < tsB
        }
    }

    /// Sort SessionEvents by sequence number (primary), which is the authoritative order.
    private static func sortEventsByTurn(_ events: [SessionEvent]) -> [SessionEvent] {
        events.sorted { a, b in
            // Primary sort: by sequence number (authoritative order)
            if a.sequence != b.sequence {
                return a.sequence < b.sequence
            }

            // Secondary sort: by timestamp (for events with same sequence, if any)
            let tsA = parseTimestamp(a.timestamp)
            let tsB = parseTimestamp(b.timestamp)
            return tsA < tsB
        }
    }

    /// Extract preview (first 3 lines) from thinking content for display
    private static func extractThinkingPreview(from content: String, maxLines: Int = 3) -> String {
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(maxLines)
        let preview = lines.joined(separator: " ")
        if preview.count > 120 {
            return String(preview.prefix(117)) + "..."
        }
        return preview
    }

    private static func parseTimestamp(_ isoString: String) -> Date {
        // Try with fractional seconds first (server events)
        let formatterWithFractions = ISO8601DateFormatter()
        formatterWithFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractions.date(from: isoString) {
            return date
        }

        // Fallback to standard format without fractional seconds (test data)
        let formatterStandard = ISO8601DateFormatter()
        formatterStandard.formatOptions = [.withInternetDateTime]
        return formatterStandard.date(from: isoString) ?? Date()
    }
}

// =============================================================================
// MARK: - Session State Reconstruction
// =============================================================================

extension UnifiedEventTransformer {

    /// Reconstructed session state from event history.
    ///
    /// This structure contains all information needed to display a session,
    /// including messages, token usage, and model info.
    struct ReconstructedState {
        var messages: [ChatMessage]
        /// Accumulated token usage across all turns (for billing/statistics)
        var totalTokenUsage: TokenUsage
        /// Last turn's input tokens (represents current context window size for progress bar)
        var lastTurnInputTokens: Int
        var currentModel: String?
        var currentTurn: Int
        var workingDirectory: String?
        /// Current reasoning level for extended thinking models
        var reasoningLevel: String?

        // Extended state (Phase 2)
        var fileActivity: FileActivityState
        var worktree: WorktreeState
        var compaction: CompactionState
        var metadata: MetadataState
        var sessionInfo: SessionInfo
        var tags: [String]

        // MARK: - Nested Types

        /// File read/write/edit activity during the session
        struct FileActivityState {
            var reads: [FileRead]
            var writes: [FileWrite]
            var edits: [FileEdit]

            struct FileRead {
                let path: String
                let timestamp: Date
                let linesStart: Int?
                let linesEnd: Int?
            }

            struct FileWrite {
                let path: String
                let timestamp: Date
                let size: Int
                let contentHash: String
            }

            struct FileEdit {
                let path: String
                let timestamp: Date
                let oldString: String
                let newString: String
                let diff: String?
            }

            init() {
                self.reads = []
                self.writes = []
                self.edits = []
            }

            /// All modified files (writes + edits)
            var modifiedFiles: [String] {
                let writeFiles = writes.map(\.path)
                let editFiles = edits.map(\.path)
                return Array(Set(writeFiles + editFiles))
            }

            /// All touched files (reads + writes + edits)
            var touchedFiles: [String] {
                let readFiles = reads.map(\.path)
                return Array(Set(readFiles + modifiedFiles))
            }
        }

        /// Git worktree activity during the session
        struct WorktreeState {
            var isAcquired: Bool
            var currentWorktree: String?
            var commits: [Commit]
            var merges: [Merge]

            struct Commit {
                let hash: String
                let message: String
                let timestamp: Date
            }

            struct Merge {
                let branch: String
                let timestamp: Date
            }

            init() {
                self.isAcquired = false
                self.currentWorktree = nil
                self.commits = []
                self.merges = []
            }
        }

        /// Context compaction state
        struct CompactionState {
            var boundaries: [Boundary]
            var summaries: [Summary]

            struct Boundary {
                let rangeFrom: String?
                let rangeTo: String?
                let originalTokens: Int
                let compactedTokens: Int
                let timestamp: Date
            }

            struct Summary {
                let summary: String
                let boundaryEventId: String
                let keyDecisions: [String]?
                let filesModified: [String]?
                let timestamp: Date
            }

            init() {
                self.boundaries = []
                self.summaries = []
            }

            /// Total compactions applied
            var compactionCount: Int { boundaries.count }

            /// Total tokens saved through compaction
            var tokensSaved: Int {
                boundaries.reduce(0) { $0 + ($1.originalTokens - $1.compactedTokens) }
            }
        }

        /// Session metadata
        struct MetadataState {
            var customData: [String: Any]
            var lastUpdated: Date?

            init() {
                self.customData = [:]
                self.lastUpdated = nil
            }
        }

        /// Session start information
        struct SessionInfo {
            var startTime: Date?
            var endTime: Date?
            var initialModel: String?
            var branchName: String?
            var forkSource: String?

            init() {
                self.startTime = nil
                self.endTime = nil
                self.initialModel = nil
                self.branchName = nil
                self.forkSource = nil
            }

            var isActive: Bool { startTime != nil && endTime == nil }
            var duration: TimeInterval? {
                guard let start = startTime else { return nil }
                let end = endTime ?? Date()
                return end.timeIntervalSince(start)
            }
        }

        init() {
            self.messages = []
            self.totalTokenUsage = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: nil, cacheCreationTokens: nil)
            self.lastTurnInputTokens = 0
            self.currentModel = nil
            self.currentTurn = 0
            self.workingDirectory = nil
            self.reasoningLevel = nil
            self.fileActivity = FileActivityState()
            self.worktree = WorktreeState()
            self.compaction = CompactionState()
            self.metadata = MetadataState()
            self.sessionInfo = SessionInfo()
            self.tags = []
        }
    }

    /// Reconstruct full session state from persisted events.
    ///
    /// This processes all events in order, extracting:
    /// - Chat messages for display
    /// - Accumulated token usage
    /// - Current model (after any switches)
    /// - Working directory
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: All events for the session
    /// - Parameter presorted: If true, events are already in correct chain order from getAncestors
    ///                        and should NOT be re-sorted. This is critical for forked sessions
    ///                        where sequence numbers reset and sorting by sequence would interleave
    ///                        parent and forked session events incorrectly.
    /// - Returns: Fully reconstructed session state
    static func reconstructSessionState(from events: [RawEvent], presorted: Bool = false) -> ReconstructedState {
        var state = ReconstructedState()

        // Only sort if events are not pre-sorted (from getAncestors)
        // For forked sessions, sequence numbers reset per-session, so sorting by sequence
        // would incorrectly interleave parent and forked events
        let sorted = presorted ? events : sortEventsByTurn(events)

        // PASS 1: Collect deleted event IDs, config state, and tool maps
        // Two-pass reconstruction ensures deletions that occur later are properly filtered
        var deletedEventIds = Set<String>()
        var toolCalls: [String: ToolCallPayload] = [:]
        var toolResults: [String: ToolResultPayload] = [:]

        for event in sorted {
            if event.type == PersistedEventType.toolCall.rawValue,
               let payload = ToolCallPayload(from: event.payload) {
                toolCalls[payload.toolCallId] = payload
            }
            if event.type == PersistedEventType.toolResult.rawValue,
               let payload = ToolResultPayload(from: event.payload) {
                toolResults[payload.toolCallId] = payload
            }
            // Collect deleted event IDs
            if event.type == PersistedEventType.messageDeleted.rawValue,
               let payload = MessageDeletedPayload(from: event.payload) {
                deletedEventIds.insert(payload.targetEventId)
            }
            // Track latest reasoning level
            if event.type == PersistedEventType.configReasoningLevel.rawValue {
                let payload = ReasoningLevelPayload(from: event.payload)
                state.reasoningLevel = payload.newLevel
            }
        }

        // PASS 2: Build messages, skipping deleted ones
        for event in sorted {
            // Skip deleted events
            if deletedEventIds.contains(event.id) {
                continue
            }
            guard let eventType = PersistedEventType(rawValue: event.type) else { continue }

            switch eventType {
            case .sessionStart:
                let payload = SessionStartPayload(from: event.payload)
                state.currentModel = payload.model
                state.workingDirectory = payload.workingDirectory
                state.sessionInfo.startTime = parseTimestamp(event.timestamp)
                state.sessionInfo.initialModel = payload.model

            case .toolResult, .toolCall:
                // Skip - tool calls are processed via message.assistant content blocks
                break

            case .messageAssistant:
                // Process content blocks in order (preserves interleaving)
                var interleaved = transformAssistantMessageInterleaved(
                    event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults,
                    allEvents: sorted  // Pass events for AskUserQuestion status detection
                )
                // Set eventId on the first message for deletion tracking
                // (interleaved may produce multiple messages from one event)
                if !interleaved.isEmpty {
                    interleaved[0].eventId = event.id
                }
                state.messages.append(contentsOf: interleaved)

                // Track token usage from assistant messages
                // totalTokenUsage: ACCUMULATE all tokens (for billing/statistics)
                // lastTurnInputTokens: LAST turn's value (for context bar display)
                let payload = AssistantMessagePayload(from: event.payload)
                if let usage = payload.tokenUsage {
                    state.totalTokenUsage = TokenUsage(
                        inputTokens: state.totalTokenUsage.inputTokens + usage.inputTokens,
                        outputTokens: state.totalTokenUsage.outputTokens + usage.outputTokens,
                        cacheReadTokens: (state.totalTokenUsage.cacheReadTokens ?? 0) + (usage.cacheReadTokens ?? 0),
                        cacheCreationTokens: (state.totalTokenUsage.cacheCreationTokens ?? 0) + (usage.cacheCreationTokens ?? 0)
                    )
                    // Context window from normalizedUsage on message.assistant (required)
                    if let contextWindow = payload.normalizedUsage?.contextWindowTokens {
                        state.lastTurnInputTokens = contextWindow
                    }
                    logger.debug("RECONSTRUCT turn \(payload.turn): lastTurnInputTokens=\(state.lastTurnInputTokens)", category: .events)
                }
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            case .messageUser, .messageSystem,
                 .notificationInterrupted, .configModelSwitch, .configReasoningLevel,
                 .contextCleared, .skillRemoved, .rulesLoaded,
                 .errorAgent, .errorTool, .errorProvider,
                 .streamThinkingComplete:
                // Debug: Log skill.removed events being processed (RawEvent version)
                if eventType == .skillRemoved {
                    logger.info("[RECONSTRUCT-RAW] Processing skill.removed event: \(event.id)", category: .events)
                }
                // Add chat message
                if var message = transformPersistedEvent(event) {
                    // Set eventId for message deletion tracking (user messages only)
                    if eventType == .messageUser {
                        message.eventId = event.id
                    }
                    state.messages.append(message)
                    // Debug: Confirm skill.removed message was created
                    if eventType == .skillRemoved {
                        logger.info("[RECONSTRUCT-RAW] skill.removed message created and appended", category: .events)
                    }
                } else if eventType == .skillRemoved {
                    logger.warning("[RECONSTRUCT-RAW] transformPersistedEvent returned nil for skill.removed", category: .events)
                }

                // Track model switches
                if eventType == .configModelSwitch,
                   let parsed = ModelSwitchPayload(from: event.payload) {
                    state.currentModel = parsed.newModel
                }

                // Track reasoning level changes (state already updated in pass 1)
                // The chat message is created above via transformPersistedEvent

            case .streamTurnEnd:
                // Only update turn counter, NOT token usage
                // Token usage is already captured in message.assistant events
                // Accumulating here would double-count tokens
                let payload = StreamTurnEndPayload(from: event.payload)
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            // MARK: - Extended State Events (Phase 2)

            case .sessionEnd:
                state.sessionInfo.endTime = parseTimestamp(event.timestamp)

            case .sessionFork:
                if let source = event.payload["sourceEventId"]?.value as? String {
                    state.sessionInfo.forkSource = source
                }

            case .sessionBranch:
                if let parsed = SessionBranchPayload(from: event.payload) {
                    state.sessionInfo.branchName = parsed.name
                }

            case .fileRead:
                if let parsed = FileReadPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.reads.append(ReconstructedState.FileActivityState.FileRead(
                        path: parsed.path,
                        timestamp: ts,
                        linesStart: parsed.linesStart,
                        linesEnd: parsed.linesEnd
                    ))
                }

            case .fileWrite:
                if let parsed = FileWritePayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.writes.append(ReconstructedState.FileActivityState.FileWrite(
                        path: parsed.path,
                        timestamp: ts,
                        size: parsed.size,
                        contentHash: parsed.contentHash
                    ))
                }

            case .fileEdit:
                if let parsed = FileEditPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.edits.append(ReconstructedState.FileActivityState.FileEdit(
                        path: parsed.path,
                        timestamp: ts,
                        oldString: parsed.oldString,
                        newString: parsed.newString,
                        diff: parsed.diff
                    ))
                }

            case .worktreeAcquired:
                state.worktree.isAcquired = true
                if let path = event.payload["path"]?.value as? String {
                    state.worktree.currentWorktree = path
                }

            case .worktreeReleased:
                state.worktree.isAcquired = false

            case .worktreeCommit:
                let ts = parseTimestamp(event.timestamp)
                let hash = event.payload["hash"]?.value as? String ?? ""
                let message = event.payload["message"]?.value as? String ?? ""
                state.worktree.commits.append(ReconstructedState.WorktreeState.Commit(
                    hash: hash,
                    message: message,
                    timestamp: ts
                ))

            case .worktreeMerged:
                let ts = parseTimestamp(event.timestamp)
                let branch = event.payload["branch"]?.value as? String ?? ""
                state.worktree.merges.append(ReconstructedState.WorktreeState.Merge(
                    branch: branch,
                    timestamp: ts
                ))

            case .compactBoundary:
                // Add chat message for UI display
                if let message = transformPersistedEvent(event) {
                    state.messages.append(message)
                }
                // Update compaction state
                if let parsed = CompactBoundaryPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.compaction.boundaries.append(ReconstructedState.CompactionState.Boundary(
                        rangeFrom: parsed.rangeFrom,
                        rangeTo: parsed.rangeTo,
                        originalTokens: parsed.originalTokens,
                        compactedTokens: parsed.compactedTokens,
                        timestamp: ts
                    ))
                }

            case .compactSummary:
                if let parsed = CompactSummaryPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.compaction.summaries.append(ReconstructedState.CompactionState.Summary(
                        summary: parsed.summary,
                        boundaryEventId: parsed.boundaryEventId,
                        keyDecisions: parsed.keyDecisions,
                        filesModified: parsed.filesModified,
                        timestamp: ts
                    ))
                }

            case .metadataUpdate:
                if let parsed = MetadataUpdatePayload(from: event.payload) {
                    state.metadata.customData[parsed.key] = parsed.newValue
                    state.metadata.lastUpdated = parseTimestamp(event.timestamp)
                }

            case .metadataTag:
                if let parsed = MetadataTagPayload(from: event.payload) {
                    if parsed.action == "add" && !state.tags.contains(parsed.tag) {
                        state.tags.append(parsed.tag)
                    } else if parsed.action == "remove" {
                        state.tags.removeAll { $0 == parsed.tag }
                    }
                }

            // Other event types are skipped for state reconstruction
            // Note: configReasoningLevel and messageDeleted are already processed in pass 1
            default:
                break
            }
        }

        return state
    }

    /// Reconstruct full session state from SessionEvents (from EventDatabase).
    ///
    /// Overload that accepts SessionEvent from the local SQLite database.
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: SessionEvents from EventDatabase (should be from getAncestors)
    /// - Parameter presorted: If true, events are already in correct chain order from getAncestors
    ///                        and should NOT be re-sorted. This is critical for forked sessions
    ///                        where sequence numbers reset and sorting by sequence would interleave
    ///                        parent and forked session events incorrectly.
    /// - Returns: Fully reconstructed session state
    static func reconstructSessionState(from events: [SessionEvent], presorted: Bool = false) -> ReconstructedState {
        var state = ReconstructedState()

        // Only sort if events are not pre-sorted (from getAncestors)
        // For forked sessions, sequence numbers reset per-session, so sorting by sequence
        // would incorrectly interleave parent and forked events
        let sorted = presorted ? events : sortEventsByTurn(events)

        // PASS 1: Collect deleted event IDs, config state, and tool maps
        // Two-pass reconstruction ensures deletions that occur later are properly filtered
        var deletedEventIds = Set<String>()
        var toolCalls: [String: ToolCallPayload] = [:]
        var toolResults: [String: ToolResultPayload] = [:]

        for event in sorted {
            if event.type == PersistedEventType.toolCall.rawValue,
               let payload = ToolCallPayload(from: event.payload) {
                toolCalls[payload.toolCallId] = payload
            }
            if event.type == PersistedEventType.toolResult.rawValue,
               let payload = ToolResultPayload(from: event.payload) {
                toolResults[payload.toolCallId] = payload
            }
            // Collect deleted event IDs
            if event.type == PersistedEventType.messageDeleted.rawValue,
               let payload = MessageDeletedPayload(from: event.payload) {
                deletedEventIds.insert(payload.targetEventId)
            }
            // Track latest reasoning level
            if event.type == PersistedEventType.configReasoningLevel.rawValue {
                let payload = ReasoningLevelPayload(from: event.payload)
                state.reasoningLevel = payload.newLevel
            }
        }

        // PASS 2: Build messages, skipping deleted ones
        for event in sorted {
            // Skip deleted events
            if deletedEventIds.contains(event.id) {
                continue
            }
            guard let eventType = PersistedEventType(rawValue: event.type) else { continue }

            switch eventType {
            case .sessionStart:
                let payload = SessionStartPayload(from: event.payload)
                state.currentModel = payload.model
                state.workingDirectory = payload.workingDirectory
                state.sessionInfo.startTime = parseTimestamp(event.timestamp)
                state.sessionInfo.initialModel = payload.model

            case .toolResult, .toolCall:
                // Skip - tool calls are processed via message.assistant content blocks
                break

            case .messageAssistant:
                // Process content blocks in order (preserves interleaving)
                var interleaved = transformAssistantMessageInterleaved(
                    event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults
                )
                // Set eventId on the first message for deletion tracking
                // (interleaved may produce multiple messages from one event)
                if !interleaved.isEmpty {
                    interleaved[0].eventId = event.id
                }
                state.messages.append(contentsOf: interleaved)

                // Track token usage from assistant messages
                // totalTokenUsage: ACCUMULATE all tokens (for billing/statistics)
                // lastTurnInputTokens: LAST turn's value (for context bar display)
                let parsed = AssistantMessagePayload(from: event.payload)
                if let usage = parsed.tokenUsage {
                    state.totalTokenUsage = TokenUsage(
                        inputTokens: state.totalTokenUsage.inputTokens + usage.inputTokens,
                        outputTokens: state.totalTokenUsage.outputTokens + usage.outputTokens,
                        cacheReadTokens: (state.totalTokenUsage.cacheReadTokens ?? 0) + (usage.cacheReadTokens ?? 0),
                        cacheCreationTokens: (state.totalTokenUsage.cacheCreationTokens ?? 0) + (usage.cacheCreationTokens ?? 0)
                    )
                    // Context window from normalizedUsage on message.assistant (required)
                    if let contextWindow = parsed.normalizedUsage?.contextWindowTokens {
                        state.lastTurnInputTokens = contextWindow
                    }
                }
                if parsed.turn > state.currentTurn {
                    state.currentTurn = parsed.turn
                }

            case .messageUser, .messageSystem,
                 .notificationInterrupted, .configModelSwitch, .configReasoningLevel,
                 .contextCleared, .skillRemoved, .rulesLoaded,
                 .errorAgent, .errorTool, .errorProvider,
                 .streamThinkingComplete:
                // Add chat message using the SessionEvent overload
                if var message = transformPersistedEvent(event) {
                    // Set eventId for message deletion tracking (user messages only)
                    if eventType == .messageUser {
                        message.eventId = event.id
                    }
                    state.messages.append(message)
                }

                // Track model switches
                if eventType == .configModelSwitch,
                   let parsed = ModelSwitchPayload(from: event.payload) {
                    state.currentModel = parsed.newModel
                }

                // Track reasoning level changes (state already updated in pass 1)
                // The chat message is created above via transformPersistedEvent

            case .streamTurnEnd:
                // Only update turn counter, NOT token usage
                // Token usage is already captured in message.assistant events
                // Accumulating here would double-count tokens
                let payload = StreamTurnEndPayload(from: event.payload)
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            // MARK: - Extended State Events (Phase 2)

            case .sessionEnd:
                state.sessionInfo.endTime = parseTimestamp(event.timestamp)

            case .sessionFork:
                if let source = event.payload["sourceEventId"]?.value as? String {
                    state.sessionInfo.forkSource = source
                }

            case .sessionBranch:
                if let parsed = SessionBranchPayload(from: event.payload) {
                    state.sessionInfo.branchName = parsed.name
                }

            case .fileRead:
                if let parsed = FileReadPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.reads.append(ReconstructedState.FileActivityState.FileRead(
                        path: parsed.path,
                        timestamp: ts,
                        linesStart: parsed.linesStart,
                        linesEnd: parsed.linesEnd
                    ))
                }

            case .fileWrite:
                if let parsed = FileWritePayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.writes.append(ReconstructedState.FileActivityState.FileWrite(
                        path: parsed.path,
                        timestamp: ts,
                        size: parsed.size,
                        contentHash: parsed.contentHash
                    ))
                }

            case .fileEdit:
                if let parsed = FileEditPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.edits.append(ReconstructedState.FileActivityState.FileEdit(
                        path: parsed.path,
                        timestamp: ts,
                        oldString: parsed.oldString,
                        newString: parsed.newString,
                        diff: parsed.diff
                    ))
                }

            case .worktreeAcquired:
                state.worktree.isAcquired = true
                if let path = event.payload["path"]?.value as? String {
                    state.worktree.currentWorktree = path
                }

            case .worktreeReleased:
                state.worktree.isAcquired = false

            case .worktreeCommit:
                let ts = parseTimestamp(event.timestamp)
                let hash = event.payload["hash"]?.value as? String ?? ""
                let message = event.payload["message"]?.value as? String ?? ""
                state.worktree.commits.append(ReconstructedState.WorktreeState.Commit(
                    hash: hash,
                    message: message,
                    timestamp: ts
                ))

            case .worktreeMerged:
                let ts = parseTimestamp(event.timestamp)
                let branch = event.payload["branch"]?.value as? String ?? ""
                state.worktree.merges.append(ReconstructedState.WorktreeState.Merge(
                    branch: branch,
                    timestamp: ts
                ))

            case .compactBoundary:
                // Add chat message for UI display
                if let message = transformPersistedEvent(event) {
                    state.messages.append(message)
                }
                // Update compaction state
                if let parsed = CompactBoundaryPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.compaction.boundaries.append(ReconstructedState.CompactionState.Boundary(
                        rangeFrom: parsed.rangeFrom,
                        rangeTo: parsed.rangeTo,
                        originalTokens: parsed.originalTokens,
                        compactedTokens: parsed.compactedTokens,
                        timestamp: ts
                    ))
                }

            case .compactSummary:
                if let parsed = CompactSummaryPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.compaction.summaries.append(ReconstructedState.CompactionState.Summary(
                        summary: parsed.summary,
                        boundaryEventId: parsed.boundaryEventId,
                        keyDecisions: parsed.keyDecisions,
                        filesModified: parsed.filesModified,
                        timestamp: ts
                    ))
                }

            case .metadataUpdate:
                if let parsed = MetadataUpdatePayload(from: event.payload) {
                    state.metadata.customData[parsed.key] = parsed.newValue
                    state.metadata.lastUpdated = parseTimestamp(event.timestamp)
                }

            case .metadataTag:
                if let parsed = MetadataTagPayload(from: event.payload) {
                    if parsed.action == "add" && !state.tags.contains(parsed.tag) {
                        state.tags.append(parsed.tag)
                    } else if parsed.action == "remove" {
                        state.tags.removeAll { $0 == parsed.tag }
                    }
                }

            // Other event types are skipped for state reconstruction
            // Note: configReasoningLevel and messageDeleted are already processed in pass 1
            default:
                break
            }
        }

        return state
    }
}
