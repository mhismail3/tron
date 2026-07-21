import Foundation

/// Client for engine-global worker inspection, invocation, and lifecycle control.
final class WorkerKernelClient: EngineDomainClient {
    func engineSurfaceSnapshot(
        sessionId: String?,
        relevanceQuery: String? = nil
    ) async throws -> EngineIntrospectionSnapshotDTO {
        try await invokeRead(
            "engine::surface_snapshot",
            EngineSurfaceSnapshotRequestDTO(relevanceQuery: relevanceQuery),
            context: optionalSessionInvocationContext(sessionId)
        )
    }

    func workers(includeRetired: Bool = true) async throws -> WorkerListResultDTO {
        try await invokeRead(
            "worker_kernel::list",
            WorkerListRequestDTO(includeRetired: includeRetired)
        )
    }

    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO {
        try await invokeRead(
            "worker_kernel::inspect",
            WorkerInspectRequestDTO(workerId: workerId)
        )
    }

    func workerRuns(workerId: String?, limit: UInt64 = 100) async throws -> WorkerRunsResultDTO {
        try await invokeRead(
            "worker_kernel::runs",
            WorkerRunsRequestDTO(workerId: workerId, limit: limit)
        )
    }

    func workerInbox(workerId: String?, limit: UInt64 = 100) async throws -> WorkerInboxResultDTO {
        try await invokeRead(
            "worker_kernel::inbox",
            WorkerRunsRequestDTO(workerId: workerId, limit: limit)
        )
    }

    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWrite(
            "worker_kernel::invoke",
            WorkerInvokeRequestDTO(
                workerId: workerId,
                input: input,
                idempotencyKey: idempotencyKey.rawValue
            ),
            idempotencyKey: idempotencyKey
        )
    }

    func setWorkerEnabled(
        _ enabled: Bool,
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        try await invokeWrite(
            enabled ? "worker_kernel::enable" : "worker_kernel::disable",
            WorkerIdRequestDTO(workerId: workerId),
            idempotencyKey: idempotencyKey
        )
    }

    func stopWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        try await invokeWrite(
            "worker_kernel::stop",
            WorkerIdRequestDTO(workerId: workerId),
            idempotencyKey: idempotencyKey
        )
    }

    func rollbackWorker(
        workerId: String,
        version: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRollbackResultDTO {
        try await invokeWrite(
            "worker_kernel::rollback",
            WorkerRollbackRequestDTO(workerId: workerId, version: version),
            idempotencyKey: idempotencyKey
        )
    }

    func retireWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        try await invokeWrite(
            "worker_kernel::retire",
            WorkerIdRequestDTO(workerId: workerId),
            idempotencyKey: idempotencyKey
        )
    }

    func purgeWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerPurgeResultDTO {
        try await invokeWrite(
            "worker_kernel::purge",
            WorkerIdRequestDTO(workerId: workerId),
            idempotencyKey: idempotencyKey
        )
    }

    func setWorkersStopped(
        _ stopped: Bool,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerStopAllResultDTO {
        try await invokeWrite(
            "worker_kernel::stop_all",
            WorkerStopAllRequestDTO(stopped: stopped),
            idempotencyKey: idempotencyKey
        )
    }

    func rotateWorkerWebhook(
        workerId: String,
        triggerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerWebhookCredentialDTO {
        try await invokeWrite(
            "worker_kernel::webhook_rotate",
            WorkerWebhookRotateRequestDTO(workerId: workerId, triggerId: triggerId),
            idempotencyKey: idempotencyKey
        )
    }

    func pollWorkerEvents(
        topic: String,
        cursor: EngineStreamCursor
    ) async throws -> EngineStreamPage {
        let connection = try requireTransport().requireConnection()
        return try await connection.poll(topic: topic, cursor: cursor, limit: 100)
    }
}
