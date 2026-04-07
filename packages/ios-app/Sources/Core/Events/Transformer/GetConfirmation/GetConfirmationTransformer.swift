import Foundation

/// Transformer for GetConfirmation tool_use content blocks.
///
/// Converts GetConfirmation tool calls into interactive confirmation chips
/// that show the action, reason, risk level, and track approval status.
enum GetConfirmationTransformer {

    /// Transform a GetConfirmation tool_use content block into a ChatMessage.
    ///
    /// - Parameters:
    ///   - toolUseId: The tool use ID from the content block
    ///   - toolCall: Optional tool call payload with full arguments
    ///   - contentBlock: The tool_use content block from message.assistant
    ///   - timestamp: Event timestamp
    ///   - turn: Turn number
    ///   - allEvents: Optional array of all events for status detection
    /// - Returns: ChatMessage with .getConfirmation content, or nil if parsing fails
    static func transform<E: EventTransformable>(
        toolUseId: String,
        toolCall: ToolCallPayload?,
        contentBlock: [String: Any],
        timestamp: Date,
        turn: Int,
        allEvents: [E]?
    ) -> ChatMessage? {
        // Parse the params from arguments
        guard let argumentsJson = ToolArgumentExtractor.extractArguments(
            toolCall: toolCall,
            contentBlock: contentBlock
        ) else {
            TronLogger.shared.warning("GetConfirmation: Could not extract arguments", category: .events)
            return nil
        }

        guard let paramsData = argumentsJson.data(using: .utf8),
              let params = try? JSONDecoder().decode(GetConfirmationParams.self, from: paramsData) else {
            TronLogger.shared.warning("GetConfirmation: Could not decode params from arguments", category: .events)
            return nil
        }

        // Determine status from subsequent events
        let detection: GetConfirmationDetectionResult
        if let events = allEvents {
            detection = GetConfirmationDetector.detectStatus(toolUseId: toolUseId, events: events)
        } else {
            detection = GetConfirmationDetectionResult(status: .pending, decision: nil, note: nil)
        }

        // Build result if decided
        let result: GetConfirmationResult?
        if let decision = detection.decision {
            result = GetConfirmationResult(
                decision: decision,
                note: detection.note,
                submittedAt: ""  // Not available from persisted data
            )
        } else {
            result = nil
        }

        let toolData = GetConfirmationToolData(
            toolCallId: toolUseId,
            params: params,
            status: detection.status,
            decision: detection.decision,
            note: detection.note,
            result: result
        )

        return ChatMessage(
            role: .assistant,
            content: .getConfirmation(toolData),
            timestamp: timestamp,
            turnNumber: turn
        )
    }
}
