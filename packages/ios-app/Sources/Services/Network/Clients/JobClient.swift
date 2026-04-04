import Foundation

/// Client for job.* RPC methods.
/// Unified interface for managing background processes and subagents.
@MainActor
final class JobClient {
    private weak var transport: (any RPCTransport)?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Access transport safely, throwing if deallocated during server change.
    private func requireTransport() throws -> any RPCTransport {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        return transport
    }

    /// Promote a blocking job to background.
    func background(jobId: String, sessionId: String) async throws {
        let ws = try requireTransport().requireConnection()

        struct Params: Codable {
            let jobId: String
            let sessionId: String
        }

        struct Result: Codable {
            let jobId: String
            let backgrounded: Bool
        }

        let _: Result = try await ws.send(
            method: "job.background",
            params: Params(jobId: jobId, sessionId: sessionId)
        )
    }

    /// Cancel a running job.
    func cancel(jobId: String, sessionId: String) async throws {
        let ws = try requireTransport().requireConnection()

        struct Params: Codable {
            let jobId: String
            let sessionId: String
        }

        struct Result: Codable {
            let jobId: String
            let cancelled: Bool
        }

        let _: Result = try await ws.send(
            method: "job.cancel",
            params: Params(jobId: jobId, sessionId: sessionId)
        )
    }

    /// Subscribe to real-time output streaming for a job.
    func subscribe(jobId: String, sessionId: String) async throws {
        let ws = try requireTransport().requireConnection()

        struct Params: Codable {
            let jobId: String
            let sessionId: String
        }

        struct Result: Codable {
            let subscribed: Bool
            let jobId: String
        }

        let _: Result = try await ws.send(
            method: "job.subscribe",
            params: Params(jobId: jobId, sessionId: sessionId)
        )
    }

    /// Stop streaming output for a job.
    func unsubscribe(jobId: String) async throws {
        let ws = try requireTransport().requireConnection()

        struct Params: Codable {
            let jobId: String
        }

        struct Result: Codable {
            let jobId: String
            let unsubscribed: Bool
        }

        let _: Result = try await ws.send(
            method: "job.unsubscribe",
            params: Params(jobId: jobId)
        )
    }
}
