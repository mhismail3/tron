import Foundation

/// Client for job engine capabilities.
/// Unified interface for managing background jobs.
final class JobClient: EngineDomainClient {

    /// Promote a blocking job to background.
    func background(jobId: String, sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        struct Params: Codable {
            let jobId: String
            let sessionId: String
        }

        struct Result: Codable {
            let jobId: String
            let backgrounded: Bool
        }

        let _: Result = try await invokeWrite(
            "job::background",
            Params(jobId: jobId, sessionId: sessionId),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    /// Cancel a running job.
    func cancel(jobId: String, sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        struct Params: Codable {
            let jobId: String
            let sessionId: String
        }

        struct Result: Codable {
            let jobId: String
            let cancelled: Bool
        }

        let _: Result = try await invokeWrite(
            "job::cancel",
            Params(jobId: jobId, sessionId: sessionId),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    /// Subscribe to real-time output streaming for a job.
    func subscribe(jobId: String, sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        struct Params: Codable {
            let jobId: String
            let sessionId: String
        }

        struct Result: Codable {
            let subscribed: Bool
            let jobId: String
        }

        let _: Result = try await invokeWrite(
            "job::subscribe",
            Params(jobId: jobId, sessionId: sessionId),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    /// Stop streaming output for a job.
    func unsubscribe(jobId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        struct Params: Codable {
            let jobId: String
        }

        struct Result: Codable {
            let jobId: String
            let unsubscribed: Bool
        }

        let _: Result = try await invokeWrite(
            "job::unsubscribe",
            Params(jobId: jobId),
            idempotencyKey: idempotencyKey
        )
    }
}
