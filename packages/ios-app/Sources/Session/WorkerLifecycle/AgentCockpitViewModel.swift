import Foundation

@Observable
@MainActor
final class AgentCockpitViewModel {
    var overview: AgentCockpitOverview = .empty(connectionState: .disconnected)
    var selectedWorkerId: String?
    var selectedPackageId: String?
    var pendingConfirmation: AgentCockpitConfirmation?
    var isRefreshing = false
    var lastError: String?

    func refresh(
        repository: any WorkerLifecycleRepository,
        connectionState: ConnectionState
    ) async {
        guard connectionState.isConnected else {
            overview = .empty(connectionState: connectionState)
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let catalog = try await repository.overview(afterRevision: nil)
            let packages = try await repository.listResources(kind: .package, lifecycle: nil, limit: 100)
            let installations = try await repository.listResources(kind: .installation, lifecycle: nil, limit: 100)
            let proposals = try await repository.listResources(kind: .proposal, lifecycle: nil, limit: 100)
            let conformanceReports = try await repository.listResources(kind: .conformanceReport, lifecycle: nil, limit: 100)
            let launchAttempts = try await repository.listResources(kind: .launchAttempt, lifecycle: nil, limit: 100)
            let runtimeSurfaceResources = try await repository.listResources(kind: .uiSurface, lifecycle: "active", limit: 25)
            let discoveryReports = try await repository.listResources(kind: .catalogDiscoveryReport, lifecycle: nil, limit: 25)
            let runtimeSurfaces = try await inspectRuntimeSurfaces(
                runtimeSurfaceResources.resources,
                repository: repository
            )

            let resourceResults = [
                packages.resources,
                installations.resources,
                proposals.resources,
                conformanceReports.resources,
                launchAttempts.resources,
            ].flatMap { $0 }

            overview = AgentCockpitProjection.project(
                snapshot: catalog,
                resources: resourceResults,
                runtimeSurfaces: runtimeSurfaces,
                discoveryReports: discoveryReports.resources,
                connectionState: connectionState
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            overview = AgentCockpitProjection.refreshFailedOverview(
                previous: overview,
                connectionState: connectionState,
                message: lastError ?? ""
            )
        }
    }

    func requestConfirmation(for action: AgentCockpitAction) {
        guard action.isEnabled else { return }
        pendingConfirmation = AgentCockpitProjection.confirmation(for: action)
    }

    func verifyCatalogDiscovery(
        repository: any WorkerLifecycleRepository,
        sessionId: String?,
        workspaceId: String?,
        connectionState: ConnectionState
    ) async {
        guard connectionState.isConnected else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await repository.createCatalogDiscoveryReport(
                reason: "runtime cockpit verification",
                sessionId: sessionId,
                workspaceId: workspaceId,
                idempotencyKey: .userAction("catalogDiscovery.conformanceReport")
            )
            await refresh(repository: repository, connectionState: connectionState)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearConfirmation() {
        pendingConfirmation = nil
    }

    func performPendingConfirmation(
        repository: any WorkerLifecycleRepository,
        sessionId: String?,
        workspaceId: String?,
        connectionState: ConnectionState
    ) async {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil
        do {
            _ = try await perform(
                confirmation.action,
                repository: repository,
                sessionId: sessionId,
                workspaceId: workspaceId
            )
            await refresh(repository: repository, connectionState: connectionState)
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func perform(
        _ action: AgentCockpitAction,
        repository: any WorkerLifecycleRepository,
        sessionId: String?,
        workspaceId: String?
    ) async throws -> WorkerLifecycleResultDTO {
        switch action.kind {
        case .installProposal:
            guard let proposalResourceId = action.proposalResourceId else {
                throw AgentCockpitError.missingProposalResource
            }
            let manifest = try await proposalManifest(
                proposalResourceId,
                repository: repository
            )
            return try await repository.installPackage(
                manifest: manifest,
                sessionId: sessionId,
                workspaceId: workspaceId,
                idempotencyKey: .userAction("workerLifecycle.installPackage")
            )
        case .enablePackage:
            let identity = try packageIdentity(from: action)
            return try await repository.enablePackage(
                packageId: identity.packageId,
                packageVersion: identity.packageVersion,
                reason: action.reason,
                sessionId: sessionId,
                workspaceId: workspaceId,
                idempotencyKey: .userAction("workerLifecycle.enablePackage")
            )
        case .disablePackage:
            let identity = try packageIdentity(from: action)
            return try await repository.disablePackage(
                packageId: identity.packageId,
                packageVersion: identity.packageVersion,
                reason: action.reason,
                sessionId: sessionId,
                workspaceId: workspaceId,
                idempotencyKey: .userAction("workerLifecycle.disablePackage")
            )
        case .launchWorker:
            let identity = try packageIdentity(from: action)
            return try await repository.launchWorker(
                packageId: identity.packageId,
                packageVersion: identity.packageVersion,
                reason: action.reason,
                sessionId: sessionId,
                workspaceId: workspaceId,
                idempotencyKey: .userAction("workerLifecycle.launchWorker")
            )
        case .stopWorker:
            guard let launchAttemptResourceId = action.launchAttemptResourceId else {
                throw AgentCockpitError.missingLaunchAttempt
            }
            return try await repository.stopWorker(
                launchAttemptResourceId: launchAttemptResourceId,
                reason: action.reason,
                sessionId: sessionId,
                workspaceId: workspaceId,
                idempotencyKey: .userAction("workerLifecycle.stopWorker")
            )
        case .retirePackage:
            let identity = try packageIdentity(from: action)
            return try await repository.retirePackage(
                packageId: identity.packageId,
                packageVersion: identity.packageVersion,
                reason: action.reason,
                sessionId: sessionId,
                workspaceId: workspaceId,
                idempotencyKey: .userAction("workerLifecycle.retirePackage")
            )
        }
    }

    private func packageIdentity(from action: AgentCockpitAction) throws -> (packageId: String, packageVersion: String) {
        guard let packageId = action.packageId?.nilIfEmpty,
              let packageVersion = action.packageVersion?.nilIfEmpty
        else {
            throw AgentCockpitError.missingPackageIdentity
        }
        return (packageId, packageVersion)
    }

    private func proposalManifest(
        _ resourceId: String,
        repository: any WorkerLifecycleRepository
    ) async throws -> [String: AnyCodable] {
        let inspection = try await repository.inspectResource(resourceId).inspection
        let current = inspection?.versions.first { version in
            version.versionId == inspection?.resource.currentVersionId
        } ?? inspection?.versions.last
        guard let manifest = current?.payload?["manifest"]?.dictionaryValue else {
            throw AgentCockpitError.missingProposalManifest
        }
        return manifest.mapValues { AnyCodable($0) }
    }

    private func inspectRuntimeSurfaces(
        _ resources: [EngineResourceDTO],
        repository: any WorkerLifecycleRepository
    ) async throws -> [AgentCockpitRuntimeSurface] {
        var surfaces: [AgentCockpitRuntimeSurface] = []
        for resource in resources {
            guard let inspection = try await repository.inspectResource(resource.resourceId).inspection,
                  let version = currentVersion(from: inspection),
                  let surface = decodeSurface(from: version.payload)
            else {
                continue
            }
            surfaces.append(
                AgentCockpitRuntimeSurface(
                    surface: surface,
                    resourceRef: UiSurfaceRefDTO(
                        resourceId: inspection.resource.resourceId,
                        versionId: version.versionId,
                        kind: inspection.resource.kind,
                        lifecycle: inspection.resource.lifecycle,
                        surfaceId: surface.surfaceId,
                        title: surface.title,
                        purpose: surface.purpose,
                        schemaVersion: surface.schemaVersion,
                        expiresAt: surface.expiresAt,
                        actions: surface.actions.map {
                            UiActionSummaryDTO(
                                actionId: $0.actionId,
                                label: $0.label,
                                expiresAt: $0.expiresAt,
                                presentation: $0.presentation
                            )
                        }
                    ),
                    lifecycle: inspection.resource.lifecycle,
                    updatedAt: inspection.resource.updatedAt
                )
            )
        }
        return surfaces
    }

    private func currentVersion(from inspection: EngineResourceInspectionDTO) -> EngineResourceVersionDTO? {
        inspection.versions.first { version in
            version.versionId == inspection.resource.currentVersionId
        } ?? inspection.versions.last
    }

    private func decodeSurface(from payload: [String: AnyCodable]?) -> UiSurfaceDTO? {
        guard let payload,
              let data = try? JSONEncoder().encode(payload)
        else {
            return nil
        }
        return try? JSONDecoder().decode(UiSurfaceDTO.self, from: data)
    }
}

enum AgentCockpitError: LocalizedError, Equatable {
    case missingPackageIdentity
    case missingProposalResource
    case missingProposalManifest
    case missingLaunchAttempt

    var errorDescription: String? {
        switch self {
        case .missingPackageIdentity:
            return "Package identity is missing."
        case .missingProposalResource:
            return "Proposal resource is missing."
        case .missingProposalManifest:
            return "Proposal manifest is unavailable."
        case .missingLaunchAttempt:
            return "Launch attempt resource is missing."
        }
    }
}
