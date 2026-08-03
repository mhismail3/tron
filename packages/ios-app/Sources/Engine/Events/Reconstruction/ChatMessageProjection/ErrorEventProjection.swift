import Foundation

/// Event projection for the durable failed-turn record.
enum ErrorEventProjection {
    /// Transform turn.failed event into a ChatMessage.
    ///
    /// Turn failed events represent errors that caused a turn to fail.
    /// Displayed as a system notification (red pill) in the chat.
    static func transformTurnFailed(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = TurnFailedPayload(from: payload) else { return nil }

        if parsed.isCancellation {
            return ChatMessage(
                role: .system,
                content: .interrupted,
                timestamp: timestamp
            )
        }

        return ChatMessage(
            role: .system,
            content: .systemEvent(.turnFailed(
                error: parsed.error,
                code: parsed.code,
                recoverable: parsed.recoverable,
                failure: parsed.failure
            )),
            timestamp: timestamp
        )
    }
}
