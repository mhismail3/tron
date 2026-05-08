import Foundation

/// Engine domain client for Claude Code session import operations.
final class ImportClient: EngineDomainClient {

    /// List Claude Code project directories.
    func listSources() async throws -> ImportListSourcesResult {
        _ = try requireTransport().requireConnection()
        return try await invokeRead("import::list_sources", EmptyParams())
    }

    /// List sessions within a Claude Code project directory.
    func listSessions(encodedDir: String) async throws -> ImportListSessionsResult {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "import::list_sessions",
            ImportListSessionsParams(encodedDir: encodedDir)
        )
    }

    /// Preview a Claude Code session before importing.
    func previewSession(sessionPath: String) async throws -> ImportSessionPreview {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "import::preview_session",
            ImportPreviewParams(sessionPath: sessionPath)
        )
    }

    /// Execute the import of a Claude Code session.
    func execute(
        sessionPath: String,
        workingDirectory: String? = nil,
        tags: [String]? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ImportExecuteResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "import::execute",
            ImportExecuteParams(
                sessionPath: sessionPath,
                workingDirectory: workingDirectory,
                tags: tags
            ),
            idempotencyKey: idempotencyKey
        )
    }
}
