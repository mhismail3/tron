import Foundation

/// Client for filesystem and git-related RPC methods.
/// Handles directory listing, file reading, and repository cloning.
@MainActor
final class FilesystemClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Filesystem Methods

    func listDirectory(path: String?, showHidden: Bool = false) async throws -> DirectoryListResult {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = FilesystemListDirParams(path: path, showHidden: showHidden)
        return try await ws.send(
            method: "filesystem.listDir",
            params: params
        )
    }

    func getHome() async throws -> HomeResult {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        return try await ws.send(
            method: "filesystem.getHome",
            params: EmptyParams()
        )
    }

    /// Create a new directory
    func createDirectory(path: String, recursive: Bool = false) async throws -> FilesystemCreateDirResult {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = FilesystemCreateDirParams(path: path, recursive: recursive)
        return try await ws.send(
            method: "filesystem.createDir",
            params: params
        )
    }

    /// Read file content from server
    func readFile(path: String) async throws -> String {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        struct ReadFileParams: Codable {
            let path: String
        }

        struct ReadFileResult: Codable {
            let content: String
        }

        let params = ReadFileParams(path: path)
        let result: ReadFileResult = try await ws.send(method: "file.read", params: params)
        return result.content
    }

    // MARK: - Git Methods

    /// Clone a Git repository to a target path
    func cloneRepository(url: String, targetPath: String) async throws -> GitCloneResult {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = GitCloneParams(url: url, targetPath: targetPath)
        return try await ws.send(
            method: "git.clone",
            params: params,
            timeout: 300.0  // 5 minutes for large repos
        )
    }
}
