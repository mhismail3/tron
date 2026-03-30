import Foundation

/// Client for process.* RPC methods.
/// Used to manage background processes (promote, cancel, list, status).
@MainActor
final class ProcessClient {
    private unowned let transport: RPCTransport

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Promote a foreground process to background.
    func promote(processId: String) async throws -> PromoteResult {
        let ws = try transport.requireConnection()

        struct Params: Codable {
            let processId: String
        }

        return try await ws.send(method: "process.promote", params: Params(processId: processId))
    }

    /// Cancel a running process.
    func cancel(processId: String) async throws -> CancelResult {
        let ws = try transport.requireConnection()

        struct Params: Codable {
            let processId: String
        }

        return try await ws.send(method: "process.cancel", params: Params(processId: processId))
    }

    /// List processes for a session.
    func list(sessionId: String) async throws -> ListResult {
        let ws = try transport.requireConnection()

        struct Params: Codable {
            let sessionId: String
        }

        return try await ws.send(method: "process.list", params: Params(sessionId: sessionId))
    }

    /// Get status of a specific process.
    func status(processId: String) async throws -> StatusResult {
        let ws = try transport.requireConnection()

        struct Params: Codable {
            let processId: String
        }

        return try await ws.send(method: "process.status", params: Params(processId: processId))
    }
}

// MARK: - Response Types

struct PromoteResult: Codable {
    let processId: String
    let promoted: Bool
}

struct CancelResult: Codable {
    let processId: String
    let cancelled: Bool
}

struct ListResult: Codable {
    let processes: [ProcessInfo]

    struct ProcessInfo: Codable {
        let processId: String
        let label: String
        let kind: String
        let state: String
        let elapsedMs: Int
        let sessionId: String
        let toolCallId: String
    }
}

struct StatusResult: Codable {
    let processId: String
    let state: String
    let label: String?
    let elapsedMs: Int?
    let result: ProcessResultPayload?

    struct ProcessResultPayload: Codable {
        let processId: String
        let output: String
        let exitCode: Int?
        let durationMs: Int
        let timedOut: Bool
        let cancelled: Bool
        let blobId: String?
    }
}
