import Foundation

/// Result of detecting AskUserQuestion status.
///
/// Contains the current status and any parsed answers if available.
struct AskUserQuestionDetectionResult {
    /// Current status: pending, answered, or superseded
    let status: AskUserQuestionStatus

    /// Parsed answers keyed by question ID (only populated if answered)
    let answers: [String: AskUserQuestionAnswer]

    /// The raw content of the answer message (only populated if answered)
    let answerMessageContent: String?
}

/// Detector for AskUserQuestion status based on subsequent events.
///
/// Examines events after the tool call to determine:
/// - **pending**: No user response yet
/// - **answered**: User responded with "[Answers to your questions]"
/// - **superseded**: User sent a different message (skipped the question)
enum AskUserQuestionDetector {

    /// Detect the status of an AskUserQuestion and extract answers if available.
    ///
    /// This generic implementation works with any `EventTransformable` type,
    /// eliminating duplication between RawEvent and SessionEvent.
    ///
    /// - Parameters:
    ///   - toolUseId: The tool call ID to find
    ///   - params: The AskUserQuestion parameters for answer parsing
    ///   - events: All events to search through
    /// - Returns: Detection result with status and any parsed answers
    static func detectStatus<E: EventTransformable>(
        toolUseId: String,
        params: AskUserQuestionParams,
        events: [E]
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
                if content.contains(AgentProtocol.askUserAnswerPrefix) {
                    // Parse the answers from the message content
                    let answers = AnswerParser.parseAnswers(from: content, params: params)
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
}
