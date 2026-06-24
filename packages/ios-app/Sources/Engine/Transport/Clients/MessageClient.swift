import Foundation

/// Client for message mutation operations.
final class MessageClient: EngineDomainClient {

    /// Delete a message from a session.
    /// This appends a message.deleted event to the event log.
    /// The message will be filtered out during reconstruction.
    func deleteMessage(
        _ sessionId: String,
        targetEventId: String,
        reason: String? = "user_request",
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> MessageDeleteResult {
        _ = try requireTransport().requireConnection()

        let params = MessageDeleteParams(sessionId: sessionId, targetEventId: targetEventId, reason: reason)
        logger.info("[DELETE] Sending delete request: sessionId=\(sessionId), targetEventId=\(targetEventId)", category: .session)

        let result: MessageDeleteResult = try await invokeWrite(
            "message::delete",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )

        logger.info("[DELETE] Delete succeeded: deletionEventId=\(result.deletionEventId), targetType=\(result.targetType)", category: .session)
        return result
    }

}
