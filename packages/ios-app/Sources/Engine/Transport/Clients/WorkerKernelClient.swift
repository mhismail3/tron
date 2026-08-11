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
            WorkerInspectRequestDTO(workerId: workerId, detail: "full")
        )
    }

    func workerRuns(
        workerId: String?,
        originSessionId: String? = nil,
        limit: UInt64 = 20,
        offset: UInt64? = nil
    ) async throws -> WorkerRunsResultDTO {
        try await invokeRead(
            "worker_kernel::runs",
            WorkerRunsRequestDTO(
                workerId: workerId,
                originSessionId: originSessionId,
                limit: limit,
                offset: offset,
                detail: "full"
            )
        )
    }

    func workerRunGraph(
        invocationId: String? = nil,
        modelToolInvocationId: String? = nil
    ) async throws -> WorkerRunsResultDTO {
        try await invokeRead(
            "worker_kernel::runs",
            WorkerRunsRequestDTO(
                workerId: nil,
                originSessionId: nil,
                invocationId: invocationId,
                modelToolInvocationId: modelToolInvocationId,
                limit: 1,
                offset: nil,
                detail: "graph"
            )
        )
    }

    func workerRunGraphs(
        originSessionId: String,
        limit: UInt64 = 20,
        offset: UInt64? = nil
    ) async throws -> WorkerRunsResultDTO {
        try await invokeRead(
            "worker_kernel::runs",
            WorkerRunsRequestDTO(
                workerId: nil,
                originSessionId: originSessionId,
                limit: limit,
                offset: offset,
                detail: "graph"
            )
        )
    }

    func workerResult(
        invocationId: String,
        pointer: String = "",
        offset: UInt64 = 0,
        limit: UInt8 = 20,
        sessionId: String? = nil
    ) async throws -> WorkerResultChunkDTO {
        try await invokeRead(
            "worker_kernel::result_read",
            WorkerResultReadRequestDTO(
                invocationId: invocationId,
                pointer: pointer,
                offset: offset,
                limit: min(max(limit, 1), 20)
            ),
            context: optionalSessionInvocationContext(sessionId)
        )
    }

    func createWorkerResultHandoff(
        invocationId: String,
        workingDirectory: String,
        model: String,
        title: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerResultHandoffDTO {
        try await invokeWrite(
            "worker_kernel::result_handoff",
            WorkerResultHandoffRequestDTO(
                invocationId: invocationId,
                workingDirectory: workingDirectory,
                model: model,
                title: title
            ),
            idempotencyKey: idempotencyKey
        )
    }

    func workerInbox(
        workerId: String?,
        limit: UInt64 = 20,
        offset: UInt64? = nil,
        attentionOnly: Bool = false
    ) async throws -> WorkerInboxResultDTO {
        try await invokeRead(
            "worker_kernel::inbox",
            WorkerInboxRequestDTO(
                workerId: workerId,
                limit: limit,
                offset: offset,
                detail: "full",
                contextAttached: nil,
                severity: nil,
                attentionOnly: attentionOnly
            )
        )
    }

    func scheduledWork(
        limit: UInt64 = 50,
        offset: UInt64? = nil
    ) async throws -> WorkerScheduledWorkResultDTO {
        try await invokeRead(
            "worker_kernel::scheduled_work",
            WorkerScheduledWorkRequestDTO(
                limit: min(max(limit, 1), 100),
                offset: offset
            )
        )
    }

    func roleReviews(
        limit: UInt64 = 50,
        offset: UInt64? = nil,
        queueLimit: UInt64 = 100,
        queueOffset: UInt64? = nil
    ) async throws -> WorkerRoleReviewListDTO {
        try await invokeRead(
            "worker_kernel::role_reviews",
            WorkerRoleReviewsRequestDTO(
                limit: min(max(limit, 1), 100),
                offset: offset,
                queueLimit: min(max(queueLimit, 1), 100),
                queueOffset: queueOffset
            )
        )
    }

    func startRoleReview(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRoleReviewProposalDTO {
        try await invokeWrite(
            "worker_kernel::role_review_start",
            WorkerRoleReviewStartRequestDTO(workerId: workerId),
            idempotencyKey: idempotencyKey
        )
    }

    func inspectRoleReview(_ proposalId: String) async throws -> WorkerRoleReviewProposalDTO {
        try await invokeRead(
            "worker_kernel::role_review_inspect",
            WorkerRoleReviewInspectRequestDTO(proposalId: proposalId)
        )
    }

    func applyRoleReview(
        proposalId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRoleReviewApplyResultDTO {
        try await invokeWrite(
            "worker_kernel::role_review_apply",
            WorkerRoleReviewApplyRequestDTO(
                proposalId: proposalId,
                confirmed: true
            ),
            idempotencyKey: idempotencyKey
        )
    }

    func rejectRoleReview(
        proposalId: String,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRoleReviewProposalDTO {
        let boundedReason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(512)
        return try await invokeWrite(
            "worker_kernel::role_review_reject",
            WorkerRoleReviewRejectRequestDTO(
                proposalId: proposalId,
                reason: boundedReason.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
            ),
            idempotencyKey: idempotencyKey
        )
    }

    func dismissWorkerInboxItem(
        inboxId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInboxDismissResultDTO {
        try await invokeWrite(
            "worker_kernel::inbox_dismiss",
            WorkerInboxDismissRequestDTO(inboxId: inboxId),
            idempotencyKey: idempotencyKey
        )
    }

    func artifactDeliveries(
        limit: UInt16 = 100,
        offset: UInt64 = 0
    ) async throws -> WorkerArtifactPageDTO {
        try await invokeRead(
            "worker_kernel::artifact_deliveries",
            WorkerArtifactListRequestDTO(
                limit: min(max(limit, 1), 200),
                offset: offset
            )
        )
    }

    func artifactContent(
        workerId: String,
        artifactId: String
    ) async throws -> WorkerArtifactContentDTO {
        try await invokeRead(
            "worker_kernel::artifact_content",
            WorkerArtifactIdentityRequestDTO(
                workerId: workerId,
                artifactId: artifactId
            )
        )
    }

    func deleteArtifact(
        workerId: String,
        artifactId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerArtifactDeleteDTO {
        try await invokeWrite(
            "worker_kernel::artifact_delete",
            WorkerArtifactIdentityRequestDTO(
                workerId: workerId,
                artifactId: artifactId
            ),
            idempotencyKey: idempotencyKey
        )
    }

    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey,
        originSessionId: String? = nil,
        mode: WorkerInvocationMode = .wait,
        model: String? = nil,
        reasoningLevel: String? = nil,
        compactResponse: Bool = false
    ) async throws -> WorkerInvocationDTO {
        try await invokeWrite(
            "worker_kernel::invoke",
            WorkerInvokeRequestDTO(
                workerId: workerId,
                input: input,
                idempotencyKey: idempotencyKey.rawValue,
                mode: mode,
                model: model,
                reasoningLevel: reasoningLevel,
                compactResponse: compactResponse ? true : nil
            ),
            idempotencyKey: idempotencyKey,
            context: optionalSessionInvocationContext(originSessionId)
        )
    }

    func cancelWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWrite(
            "worker_kernel::cancel",
            WorkerCancelRequestDTO(invocationId: invocationId),
            idempotencyKey: idempotencyKey
        )
    }

    func detachWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWrite(
            "worker_kernel::detach",
            WorkerCancelRequestDTO(invocationId: invocationId),
            idempotencyKey: idempotencyKey
        )
    }

    func awaitWorkerInvocation(
        invocationId: String,
        timeoutSeconds: UInt8 = 10
    ) async throws -> WorkerAwaitResultDTO {
        try await invokeRead(
            "worker_kernel::await",
            WorkerAwaitRequestDTO(
                invocationId: invocationId,
                timeoutSeconds: min(timeoutSeconds, 10)
            )
        )
    }

    func retryWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWrite(
            "worker_kernel::invoke",
            WorkerRetryRequestDTO(
                retryOfInvocationId: invocationId,
                mode: .wait
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

    func ensureWorkerEventSubscriptions() async throws {
        try await requireTransport().ensureWorkerEventSubscriptions()
    }
}
