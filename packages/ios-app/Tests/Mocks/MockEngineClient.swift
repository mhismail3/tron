import Foundation
@testable import TronMobile

/// Mock Engine Client for testing workspace validation
@MainActor
class MockEngineClient {
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
    /// Returns `true` if path exists, `false` if confirmed deleted (EngineProtocolError),
    /// or `nil` if indeterminate (connection/transport error).
    func validateWorkspacePath(_ path: String) async -> Bool? {
        guard !path.isEmpty else { return false }
        do {
            _ = try await listDirectory(path: path, showHidden: false)
            return true
        } catch is EngineProtocolError {
            return false
        } catch {
            return nil
        }
    }
}

/// engine protocol errors for testing
enum MockEngineProtocolError: Error, LocalizedError {
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
