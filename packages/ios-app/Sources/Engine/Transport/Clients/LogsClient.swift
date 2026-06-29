import Foundation

/// Client for server/client log evidence operations.
final class LogsClient: EngineDomainClient {

    /// Fetch recent server logs for an explicit user-generated diagnostics bundle.
    func recentLogs(
        limit: Int = 1000,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        traceId: String? = nil
    ) async throws -> LogsRecentResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "logs::recent",
            LogsRecentParams(
                limit: min(max(limit, 1), 1000),
                sessionId: sessionId,
                workspaceId: workspaceId,
                traceId: traceId
            )
        )
    }

    /// Ingest structured client logs into the server database.
    func ingestLogs(
        entries: [ClientLogEntry],
        idempotencyKey: EngineIdempotencyKey,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        traceId: String? = nil
    ) async throws -> LogsIngestResult {
        _ = try requireTransport().requireConnection()

        let params = LogsIngestParams(
            entries: entries,
            sessionId: sessionId,
            workspaceId: workspaceId,
            traceId: traceId
        )
        let result: LogsIngestResult = try await invokeWrite(
            "logs::ingest",
            params,
            idempotencyKey: idempotencyKey
        )

        return result
    }

}
