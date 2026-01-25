import Foundation

/// Transformer for AskUserQuestion tool_use content blocks.
///
/// Converts AskUserQuestion tool calls into interactive question chips
/// that show questions and track answer status.
enum AskUserQuestionTransformer {

    /// Transform an AskUserQuestion tool_use content block into a ChatMessage.
    ///
    /// This generic implementation works with any `EventTransformable` type,
    /// eliminating duplication between RawEvent and SessionEvent.
    ///
    /// - Parameters:
    ///   - toolUseId: The tool use ID from the content block
    ///   - toolCall: Optional tool call payload with full arguments
    ///   - contentBlock: The tool_use content block from message.assistant
    ///   - timestamp: Event timestamp
    ///   - tokenUsage: Optional token usage (not used for tool messages)
    ///   - model: Optional model name
    ///   - turn: Turn number
    ///   - allEvents: Optional array of all events for status detection
    /// - Returns: ChatMessage with .askUserQuestion content, or nil if parsing fails
    static func transform<E: EventTransformable>(
        toolUseId: String,
        toolCall: ToolCallPayload?,
        contentBlock: [String: Any],
        timestamp: Date,
        tokenUsage: TokenUsage?,
        model: String?,
        turn: Int,
        allEvents: [E]?
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
            TronLogger.shared.warning("AskUserQuestion: Could not extract arguments", category: .events)
            return nil
        }

        guard let paramsData = argumentsJson.data(using: .utf8),
              let params = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData) else {
            TronLogger.shared.warning("AskUserQuestion: Could not decode params from arguments", category: .events)
            return nil
        }

        // Determine status and parse answers from subsequent events
        let detection: AskUserQuestionDetectionResult
        if let events = allEvents {
            detection = AskUserQuestionDetector.detectStatus(toolUseId: toolUseId, params: params, events: events)
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
}
