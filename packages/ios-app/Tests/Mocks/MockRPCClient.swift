import Foundation
@testable import TronMobile

/// Mock RPC Client for testing workspace validation
@MainActor
class MockRPCClient {
    var connectionState: ConnectionState = .connected
    var listDirectoryCallCount = 0
    var listDirectoryError: Error?

    func listDirectory(path: String?, showHidden: Bool) async throws -> DirectoryListResult {
        listDirectoryCallCount += 1
        if let error = listDirectoryError {
            throw error
        }
        return DirectoryListResult(
            path: path ?? "/",
            parent: nil,
            entries: []
        )
    }

    /// Validate if a workspace path exists.
    /// Returns `true` if path exists, `false` if confirmed deleted (RPCError),
    /// or `nil` if indeterminate (connection/transport error).
    func validateWorkspacePath(_ path: String) async -> Bool? {
        guard !path.isEmpty else { return false }
        do {
            _ = try await listDirectory(path: path, showHidden: false)
            return true
        } catch is RPCError {
            return false
        } catch {
            return nil
        }
    }
}

/// RPC errors for testing
enum MockRPCError: Error, LocalizedError {
    case filesystemError(String)
    case connectionNotEstablished

    var errorDescription: String? {
        switch self {
        case .filesystemError(let message):
            return message
        case .connectionNotEstablished:
            return "Connection not established"
        }
    }
}
