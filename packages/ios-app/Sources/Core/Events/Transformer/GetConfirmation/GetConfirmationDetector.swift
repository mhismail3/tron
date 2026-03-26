import Foundation

/// Result of detecting GetConfirmation status.
struct GetConfirmationDetectionResult {
    /// Current status: pending, approved, denied, or superseded
    let status: GetConfirmationStatus

    /// The user's decision (only populated if approved or denied)
    let decision: ConfirmationDecision?

    /// Optional note from the user's response
    let note: String?
}

/// Detector for GetConfirmation status based on subsequent events.
///
/// Examines events after the tool call to determine:
/// - **pending**: No user response yet
/// - **approved**: User responded with "[Confirmation response]" containing "Decision: Approved"
/// - **denied**: User responded with "[Confirmation response]" containing "Decision: Denied"
/// - **superseded**: User sent a different message (skipped the confirmation)
enum GetConfirmationDetector {

    /// Detect the status of a GetConfirmation and extract the decision if available.
    static func detectStatus<E: EventTransformable>(
        toolUseId: String,
        events: [E]
    ) -> GetConfirmationDetectionResult {
        // Find the tool.call event index for this toolUseId
        guard let toolCallIndex = events.firstIndex(where: {
            $0.type == PersistedEventType.toolCall.rawValue &&
            (ToolCallPayload(from: $0.payload)?.toolCallId == toolUseId)
        }) else {
            return GetConfirmationDetectionResult(status: .pending, decision: nil, note: nil)
        }

        // Look at subsequent events for user messages
        for i in (toolCallIndex + 1)..<events.count {
            let event = events[i]
            if event.type == PersistedEventType.messageUser.rawValue {
                guard let content = event.payload["content"]?.value as? String else { continue }
                if content.contains(AgentProtocol.confirmationAnswerPrefix) {
                    let parsed = parseConfirmationResponse(from: content)
                    return GetConfirmationDetectionResult(
                        status: parsed.decision == .approved ? .approved : .denied,
                        decision: parsed.decision,
                        note: parsed.note
                    )
                } else {
                    // User sent a different message - confirmation was skipped
                    return GetConfirmationDetectionResult(status: .superseded, decision: nil, note: nil)
                }
            }
        }

        // No user message after - still pending
        return GetConfirmationDetectionResult(status: .pending, decision: nil, note: nil)
    }

    /// Parse the decision and optional note from a confirmation response message.
    ///
    /// Expected format:
    /// ```
    /// [Confirmation response]
    ///
    /// Action: Install ffmpeg via brew
    /// Decision: Approved
    /// Note: Go ahead
    /// ```
    static func parseConfirmationResponse(from content: String) -> (decision: ConfirmationDecision, note: String?) {
        let lines = content.components(separatedBy: "\n")
        var decision: ConfirmationDecision = .denied  // Default to denied if unparseable
        var note: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Decision:") {
                let value = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                if value == ConfirmationDecision.approved.rawValue {
                    decision = .approved
                } else {
                    decision = .denied
                }
            } else if trimmed.hasPrefix("Note:") {
                let value = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    note = value
                }
            }
        }

        return (decision, note)
    }
}
