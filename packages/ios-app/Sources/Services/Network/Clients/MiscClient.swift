import Foundation

/// Client for miscellaneous engine capabilities.
/// Handles system, device token, memory, message, and log operations.
final class MiscClient: EngineDomainClient {

    // MARK: - System Methods

    func ping() async throws {
        _ = try requireTransport().requireConnection()

        let _: SystemPingResult = try await invokeRead(
            "system::ping",
            SystemPingParams(
                protocolVersion: 1,
                clientVersion: AppConstants.canonicalVersion
            )
        )
    }

    func getSystemInfo() async throws -> SystemInfoResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "system::get_info",
            EmptyParams()
        )
    }

    // MARK: - Message Methods

    /// Delete a message from a session.
    /// This appends a message.deleted event to the event log.
    /// The message will be filtered out during reconstruction (two-pass).
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

    // MARK: - Logs Methods

    /// Fetch recent server logs for an explicit user-generated diagnostics bundle.
    func recentLogs(limit: Int = 1000) async throws -> LogsRecentResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "logs::recent",
            LogsRecentParams(limit: min(max(limit, 1), 1000))
        )
    }

    /// Ingest structured client logs into the server database.
    func ingestLogs(entries: [ClientLogEntry], idempotencyKey: EngineIdempotencyKey) async throws -> LogsIngestResult {
        _ = try requireTransport().requireConnection()

        let params = LogsIngestParams(entries: entries)
        let result: LogsIngestResult = try await invokeWrite(
            "logs::ingest",
            params,
            idempotencyKey: idempotencyKey
        )

        return result
    }

    // MARK: - Diagnostics (debug / beta only)

    #if DEBUG || BETA
    /// Fetch a structured snapshot of server identity, session counts,
    /// and the full engine protocol method surface. Debug-only — the production
    /// binary has no UI that consumes it.
    func getDiagnostics() async throws -> SystemDiagnosticsResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "system::get_diagnostics",
            EmptyParams()
        )
    }
    #endif
}
