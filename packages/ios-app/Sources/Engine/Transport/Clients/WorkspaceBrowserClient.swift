import Foundation

final class WorkspaceBrowserClient: EngineDomainClient {
    func getHome() async throws -> WorkspaceHomeResult {
        _ = try requireTransport().requireConnection()
        return try await invokeRead("filesystem::get_home", EmptyParams())
    }

    func listDirectory(
        path: String?,
        showHidden: Bool = false
    ) async throws -> WorkspaceDirectoryListResult {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "filesystem::list_dir",
            WorkspaceListDirectoryParams(path: path, showHidden: showHidden)
        )
    }

    func createDirectory(
        path: String,
        recursive: Bool = false,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkspaceCreateDirectoryResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "filesystem::create_dir",
            WorkspaceCreateDirectoryParams(path: path, recursive: recursive),
            idempotencyKey: idempotencyKey
        )
    }
}
