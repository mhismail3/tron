import Foundation

/// RPC domain client for Claude Code session import operations.
final class ImportClient: RPCDomainClient {

    /// List Claude Code project directories.
    func listSources() async throws -> ImportListSourcesResult {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(method: "import.listSources", params: EmptyParams())
    }

    /// List sessions within a Claude Code project directory.
    func listSessions(encodedDir: String) async throws -> ImportListSessionsResult {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(
            method: "import.listSessions",
            params: ImportListSessionsParams(encodedDir: encodedDir)
        )
    }

    /// Preview a Claude Code session before importing.
    func previewSession(sessionPath: String) async throws -> ImportSessionPreview {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(
            method: "import.previewSession",
            params: ImportPreviewParams(sessionPath: sessionPath)
        )
    }

    /// Execute the import of a Claude Code session.
    func execute(
        sessionPath: String,
        workingDirectory: String? = nil,
        tags: [String]? = nil
    ) async throws -> ImportExecuteResult {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(
            method: "import.execute",
            params: ImportExecuteParams(
                sessionPath: sessionPath,
                workingDirectory: workingDirectory,
                tags: tags
            )
        )
    }
}
