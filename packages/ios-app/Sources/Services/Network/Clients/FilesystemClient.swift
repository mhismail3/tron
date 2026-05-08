import Foundation

/// Client for filesystem and git-related engine capabilities.
/// Handles directory listing, file reading, and repository cloning.
final class FilesystemClient: EngineDomainClient {

    // MARK: - Filesystem Methods

    func listDirectory(path: String?, showHidden: Bool = false) async throws -> DirectoryListResult {
        _ = try requireTransport().requireConnection()

        let params = FilesystemListDirParams(path: path, showHidden: showHidden)
        return try await invokeRead(
            "filesystem::list_dir",
            params
        )
    }

    func getHome() async throws -> HomeResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "filesystem::get_home",
            EmptyParams()
        )
    }

    /// Create a new directory
    func createDirectory(
        path: String,
        recursive: Bool = false,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> FilesystemCreateDirResult {
        _ = try requireTransport().requireConnection()

        let params = FilesystemCreateDirParams(path: path, recursive: recursive)
        return try await invokeWrite(
            "filesystem::create_dir",
            params,
            idempotencyKey: idempotencyKey
        )
    }

    /// Read file content from server
    func readFile(path: String) async throws -> String {
        _ = try requireTransport().requireConnection()

        struct ReadFileParams: Codable {
            let path: String
        }

        struct ReadFileResult: Codable {
            let content: String
        }

        let params = ReadFileParams(path: path)
        let result: ReadFileResult = try await invokeRead("filesystem::read_file", params)
        return result.content
    }

    // MARK: - Git Methods

    /// Clone a Git repository to a target path
    func cloneRepository(
        url: String,
        targetPath: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> GitCloneResult {
        _ = try requireTransport().requireConnection()

        let params = GitCloneParams(url: url, targetPath: targetPath)
        return try await invokeWrite(
            "git::clone",
            params,
            idempotencyKey: idempotencyKey,
            timeout: 300.0
        )
    }
}
