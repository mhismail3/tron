import Foundation

/// Client for catalog-backed worker lifecycle inspection and lifecycle mutations.
final class WorkerLifecycleClient: EngineDomainClient {
    func overview(
        afterRevision: UInt64? = nil,
        limit: UInt64? = nil,
        ownerWorker: String? = nil
    ) async throws -> CatalogWatchSnapshotDTO {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "catalog::watch_snapshot",
            CatalogWatchSnapshotRequestDTO(
                afterRevision: afterRevision,
                limit: limit,
                classes: nil,
                kinds: nil,
                subjectPrefix: nil,
                ownerWorker: ownerWorker
            )
        )
    }

    func listResources(
        kind: WorkerLifecycleResourceKind,
        lifecycle: String? = nil,
        limit: UInt64 = 100
    ) async throws -> ResourceListResultDTO {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "resource::list",
            ResourceListRequestDTO(
                kind: kind.rawValue,
                scopeKind: nil,
                scopeValue: nil,
                lifecycle: lifecycle,
                limit: limit
            )
        )
    }

    func inspectResource(_ resourceId: String) async throws -> ResourceInspectResultDTO {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "resource::inspect",
            ResourceInspectRequestDTO(resourceId: resourceId)
        )
    }

    func proposePackageChange(
        manifest: [String: AnyCodable],
        summary: String,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        let request = WorkerLifecycleProposalRequestDTO(
            manifest: manifest,
            summary: summary,
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        return try await invokeWrite(
            "worker_lifecycle::propose_package_change",
            request,
            idempotencyKey: idempotencyKey,
            context: invocationContext(sessionId: sessionId, workspaceId: workspaceId)
        )
    }

    func installPackage(
        manifest: [String: AnyCodable],
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        let request = WorkerLifecycleManifestRequestDTO(
            manifest: manifest,
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        return try await invokeWrite(
            "worker_lifecycle::install_package",
            request,
            idempotencyKey: idempotencyKey,
            context: invocationContext(sessionId: sessionId, workspaceId: workspaceId)
        )
    }

    func enablePackage(
        packageId: String,
        packageVersion: String,
        reason: String? = nil,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await packageRefWrite(
            functionId: "worker_lifecycle::enable_package",
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func disablePackage(
        packageId: String,
        packageVersion: String,
        reason: String? = nil,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await packageRefWrite(
            functionId: "worker_lifecycle::disable_package",
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func launchWorker(
        packageId: String,
        packageVersion: String,
        reason: String? = nil,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await packageRefWrite(
            functionId: "worker_lifecycle::launch_worker",
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func stopWorker(
        launchAttemptResourceId: String,
        reason: String? = nil,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        let request = WorkerLifecycleStopRequestDTO(
            launchAttemptResourceId: launchAttemptResourceId,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        return try await invokeWrite(
            "worker_lifecycle::stop_worker",
            request,
            idempotencyKey: idempotencyKey,
            context: invocationContext(sessionId: sessionId, workspaceId: workspaceId)
        )
    }

    func retirePackage(
        packageId: String,
        packageVersion: String,
        reason: String? = nil,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await packageRefWrite(
            functionId: "worker_lifecycle::retire_package",
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    private func packageRefWrite(
        functionId: EngineFunctionId,
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        let request = WorkerLifecyclePackageRefRequestDTO(
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        return try await invokeWrite(
            functionId,
            request,
            idempotencyKey: idempotencyKey,
            context: invocationContext(sessionId: sessionId, workspaceId: workspaceId)
        )
    }

    private func invocationContext(sessionId: String?, workspaceId: String?) -> EngineInvocationContext? {
        guard sessionId != nil || workspaceId != nil else { return nil }
        return EngineInvocationContext(sessionId: sessionId, workspaceId: workspaceId)
    }
}
