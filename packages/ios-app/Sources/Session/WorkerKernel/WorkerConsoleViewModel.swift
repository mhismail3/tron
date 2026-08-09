import Foundation

private enum WorkerConsoleRefreshScope {
    case summary
    case activity
    case results
}

@Observable
@MainActor
final class WorkerConsoleViewModel {
    var engineSnapshot: EngineIntrospectionSnapshotDTO?
    var workers: [WorkerSummaryDTO] = []
    var activityRuns: [WorkerInvocationDTO] = []
    var activityResults: [WorkerInboxItemDTO] = []
    var selectedWorkerId: String?
    var inspection: WorkerInspectResultDTO?
    var runs: [WorkerInvocationDTO] = []
    var attention: [WorkerInboxItemDTO] = []
    var selectedResults: [WorkerInboxItemDTO] = []
    var webhookCredential: WorkerWebhookCredentialDTO?
    var isRefreshing = false
    var isLoadingSelection = false
    var isMutating = false
    var isLoadingMoreActivity = false
    var isLoadingMoreResults = false
    var hasLoaded = false
    private(set) var hasLoadedActivity = false
    private(set) var hasLoadedResults = false
    var stopAll = false
    var lastError: String?
    var monitoringError: String?
    private(set) var activityRunsNextOffset: UInt64?
    private(set) var activityResultsNextOffset: UInt64?
    private var activeRefreshScope: WorkerConsoleRefreshScope?
    private var pendingRefreshScope: WorkerConsoleRefreshScope?
    /// Retires reads from a replaced server even if task cancellation races a
    /// response that was already being decoded.
    private var projectionGeneration = 0

    var selectedWorker: WorkerSummaryDTO? {
        workers.first { $0.workerId == selectedWorkerId }
    }

    /// Current operational inventory, preserving the engine's canonical order.
    var activeWorkers: [WorkerSummaryDTO] {
        workers.filter { !$0.retired }
    }

    /// Ordinary workers remain dynamically replaceable because they own no
    /// engine hook. Direct model exposure does not imply engine ownership.
    var dynamicWorkers: [WorkerSummaryDTO] {
        activeWorkers.filter { architecture(for: $0.workerId)?.engineHooks.isEmpty != false }
    }

    /// Workers with an explicit engine hook are compatibility-sensitive
    /// specialists and are displayed separately from the dynamic inventory.
    var engineSpecialistWorkers: [WorkerSummaryDTO] {
        activeWorkers.filter { architecture(for: $0.workerId)?.engineHooks.isEmpty == false }
    }

    /// Retained historical workers shown separately after the active inventory.
    var retiredWorkers: [WorkerSummaryDTO] {
        workers.filter(\.retired)
    }

    var selectedWorkerArchitecture: WorkerArchitectureNodeDTO? {
        guard let selectedWorkerId else { return nil }
        return architecture(for: selectedWorkerId)
    }

    func architecture(for workerId: String) -> WorkerArchitectureNodeDTO? {
        engineSnapshot?.workerArchitecture?.first { $0.workerId == workerId }
    }

    func callers(of workerId: String) -> [WorkerArchitectureNodeDTO] {
        (engineSnapshot?.workerArchitecture ?? [])
            .filter { worker in
                worker.calls.contains { $0.targetWorkerId == workerId }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func workerName(for workerId: String) -> String {
        workers.first { $0.workerId == workerId }?.name
            ?? WorkerConsolePresentation.displayLabel(workerId)
    }

    func callerWorkerName(for run: WorkerInvocationDTO) -> String? {
        guard let parentInvocationId = run.parentWorkerInvocationId,
              let parent = (activityRuns + runs).first(where: {
                  $0.invocationId == parentInvocationId
              }) else {
            return nil
        }
        return workerName(for: parent.workerId)
    }

    var healthyCount: Int {
        workers.filter { $0.enabled && $0.health == "healthy" }.count
    }

    var enabledCount: Int {
        workers.filter { $0.enabled && !$0.retired }.count
    }

    var unhealthyWorkerCount: Int {
        workers.filter {
            WorkerConsolePresentation.status(for: $0).kind == .needsAttention
        }.count
    }

    var primitiveTools: [EngineSurfaceToolDTO] {
        engineSnapshot?.fixedTools ?? []
    }

    var primitiveToolGroups: [EnginePrimitiveGroup] {
        EngineDashboardPresentation.primitiveGroups(primitiveTools)
    }

    var availableWorkerTools: [AvailableWorkerToolDTO] {
        engineSnapshot?.surface.availableWorkers ?? []
    }

    var activeEngineHooks: [EngineHookOwnerDTO] {
        engineSnapshot?.activeEngineHooks ?? []
    }

    var primitiveToolCount: Int {
        primitiveTools.count
    }

    var availableWorkerCount: Int {
        Int(engineSnapshot?.surface.availableWorkerCount ?? 0)
    }

    func refresh(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        await refreshSummary(repository: repository, connectionState: connectionState)
        await requestRefresh(
            scope: .activity,
            repository: repository,
            connectionState: connectionState
        )
    }

    func ensureActivityLoaded(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard !hasLoadedActivity else { return }
        await requestRefresh(
            scope: .activity,
            repository: repository,
            connectionState: connectionState
        )
    }

    func refreshResults(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        await refreshSummary(repository: repository, connectionState: connectionState)
        await requestRefresh(
            scope: .results,
            repository: repository,
            connectionState: connectionState
        )
    }

    func ensureResultsLoaded(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard !hasLoadedResults else { return }
        await requestRefresh(
            scope: .results,
            repository: repository,
            connectionState: connectionState
        )
    }

    func refreshSummary(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        await requestRefresh(
            scope: .summary,
            repository: repository,
            connectionState: connectionState
        )
    }

    func ensureSummaryLoaded(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard !hasLoaded else { return }
        await refreshSummary(repository: repository, connectionState: connectionState)
    }

    private func requestRefresh(
        scope: WorkerConsoleRefreshScope,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        if isRefreshing {
            if !Self.refresh(activeRefreshScope, subsumes: scope) {
                pendingRefreshScope = scope
            }
            return
        }

        let projectionTicket = projectionGeneration
        isRefreshing = true
        defer {
            if projectionTicket == projectionGeneration {
                activeRefreshScope = nil
                isRefreshing = false
            }
        }

        var nextScope = scope
        repeat {
            activeRefreshScope = nextScope
            pendingRefreshScope = nil
            await performRefresh(
                scope: nextScope,
                repository: repository,
                connectionState: connectionState,
                projectionTicket: projectionTicket
            )
            guard projectionTicket == projectionGeneration,
                  let pendingRefreshScope else { return }
            nextScope = pendingRefreshScope
        } while true
    }

    private static func refresh(
        _ active: WorkerConsoleRefreshScope?,
        subsumes requested: WorkerConsoleRefreshScope
    ) -> Bool {
        guard let active else { return false }
        if active == requested { return true }
        return requested == .summary && active != .summary
    }

    private func performRefresh(
        scope: WorkerConsoleRefreshScope,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState,
        projectionTicket: Int
    ) async {
        guard projectionTicket == projectionGeneration,
              connectionState.isConnected else {
            // A transport epoch is temporary. Keep the last authoritative
            // projection visible and read-only until continuity refreshes it.
            return
        }

        do {
            switch scope {
            case .summary:
                let snapshot = try await repository.engineSurfaceSnapshot(
                    sessionId: nil,
                    relevanceQuery: nil
                )
                guard !Task.isCancelled,
                      projectionTicket == projectionGeneration else { return }
                apply(snapshot)
                hasLoaded = true
            case .activity:
                let runsRequest = Task { @MainActor in
                    try await repository.workerRuns(workerId: nil, limit: 20)
                }
                let snapshotRequest: Task<EngineIntrospectionSnapshotDTO, Error>? = if hasLoaded {
                    nil
                } else {
                    Task { @MainActor in
                        try await repository.engineSurfaceSnapshot(
                            sessionId: nil,
                            relevanceQuery: nil
                        )
                    }
                }
                defer {
                    runsRequest.cancel()
                    snapshotRequest?.cancel()
                }
                let globalRuns = try await runsRequest.value
                let snapshot = try await snapshotRequest?.value
                guard !Task.isCancelled,
                      projectionTicket == projectionGeneration else { return }
                if let snapshot {
                    apply(snapshot)
                    hasLoaded = true
                }
                activityRuns = globalRuns.runs
                activityRunsNextOffset = globalRuns.nextOffset
                hasLoadedActivity = true
            case .results:
                let resultsRequest = Task { @MainActor in
                    try await repository.workerInbox(
                        workerId: nil,
                        limit: 20,
                        offset: nil,
                        attentionOnly: false
                    )
                }
                let snapshotRequest: Task<EngineIntrospectionSnapshotDTO, Error>? = if hasLoaded {
                    nil
                } else {
                    Task { @MainActor in
                        try await repository.engineSurfaceSnapshot(
                            sessionId: nil,
                            relevanceQuery: nil
                        )
                    }
                }
                defer {
                    resultsRequest.cancel()
                    snapshotRequest?.cancel()
                }
                let globalResults = try await resultsRequest.value
                let snapshot = try await snapshotRequest?.value
                guard !Task.isCancelled,
                      projectionTicket == projectionGeneration else { return }
                if let snapshot {
                    apply(snapshot)
                    hasLoaded = true
                }
                activityResults = globalResults.items
                activityResultsNextOffset = globalResults.nextOffset
                hasLoadedResults = true
            }

            if let selectedWorkerId,
               !workers.contains(where: { $0.workerId == selectedWorkerId }) {
                self.selectedWorkerId = nil
                inspection = nil
                runs = []
                attention = []
                selectedResults = []
            }
            lastError = nil
        } catch {
            guard projectionTicket == projectionGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                lastError = error.localizedDescription
            }
        }
    }

    private func apply(_ snapshot: EngineIntrospectionSnapshotDTO) {
        engineSnapshot = snapshot
        workers = snapshot.workers
        stopAll = snapshot.dispatchStopped
    }

    func resetForServerChange() {
        projectionGeneration &+= 1
        clearServerProjection()
        activeRefreshScope = nil
        pendingRefreshScope = nil
        isRefreshing = false
        isLoadingSelection = false
        isLoadingMoreActivity = false
        isLoadingMoreResults = false
        isMutating = false
        hasLoaded = false
        hasLoadedActivity = false
        hasLoadedResults = false
        lastError = nil
        monitoringError = nil
    }

    private func clearServerProjection() {
        engineSnapshot = nil
        workers = []
        activityRuns = []
        activityResults = []
        activityRunsNextOffset = nil
        activityResultsNextOffset = nil
        selectedWorkerId = nil
        inspection = nil
        runs = []
        attention = []
        selectedResults = []
        stopAll = false
    }

    func loadOlderActivityRuns(repository: any WorkerKernelRepository) async {
        guard let offset = activityRunsNextOffset, !isLoadingMoreActivity else { return }
        let projectionTicket = projectionGeneration
        isLoadingMoreActivity = true
        defer {
            if projectionTicket == projectionGeneration {
                isLoadingMoreActivity = false
            }
        }
        do {
            let page = try await repository.workerRuns(
                workerId: nil,
                originSessionId: nil,
                limit: 20,
                offset: offset
            )
            guard !Task.isCancelled,
                  projectionTicket == projectionGeneration else { return }
            Self.appendUnique(page.runs, to: &activityRuns, id: \.invocationId)
            activityRunsNextOffset = page.nextOffset
            lastError = nil
        } catch {
            guard projectionTicket == projectionGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                lastError = error.localizedDescription
            }
        }
    }

    func loadOlderActivityResults(repository: any WorkerKernelRepository) async {
        guard let offset = activityResultsNextOffset, !isLoadingMoreResults else { return }
        let projectionTicket = projectionGeneration
        isLoadingMoreResults = true
        defer {
            if projectionTicket == projectionGeneration {
                isLoadingMoreResults = false
            }
        }
        do {
            let page = try await repository.workerInbox(
                workerId: nil,
                limit: 20,
                offset: offset,
                attentionOnly: false
            )
            guard !Task.isCancelled,
                  projectionTicket == projectionGeneration else { return }
            Self.appendUnique(page.items, to: &activityResults, id: \.inboxId)
            activityResultsNextOffset = page.nextOffset
            lastError = nil
        } catch {
            guard projectionTicket == projectionGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                lastError = error.localizedDescription
            }
        }
    }

    func select(_ workerId: String, repository: any WorkerKernelRepository) async {
        let projectionTicket = projectionGeneration
        selectedWorkerId = workerId
        inspection = nil
        runs = []
        attention = []
        selectedResults = []
        webhookCredential = nil
        isLoadingSelection = true
        defer {
            if projectionTicket == projectionGeneration {
                isLoadingSelection = false
            }
        }
        do {
            try await loadWorker(
                workerId,
                repository: repository,
                projectionTicket: projectionTicket
            )
            guard projectionTicket == projectionGeneration,
                  selectedWorkerId == workerId else { return }
            lastError = nil
        } catch {
            guard projectionTicket == projectionGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                lastError = error.localizedDescription
            }
        }
    }

    /// Refresh the currently presented worker without discarding its last
    /// authoritative projection during a temporary transport epoch.
    func reconcileSelection(repository: any WorkerKernelRepository) async {
        guard let selectedWorkerId else { return }
        let projectionTicket = projectionGeneration
        let showsLoadingState = inspection == nil
        if showsLoadingState {
            isLoadingSelection = true
        }
        defer {
            if showsLoadingState,
               projectionTicket == projectionGeneration {
                isLoadingSelection = false
            }
        }
        do {
            try await loadWorker(
                selectedWorkerId,
                repository: repository,
                projectionTicket: projectionTicket
            )
            guard projectionTicket == projectionGeneration,
                  self.selectedWorkerId == selectedWorkerId else { return }
            lastError = nil
        } catch {
            guard projectionTicket == projectionGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                lastError = error.localizedDescription
            }
        }
    }

    func ensureSelectionLoaded(repository: any WorkerKernelRepository) async {
        guard inspection == nil else { return }
        await reconcileSelection(repository: repository)
    }

    /// Presents already-read authoritative worker projections without issuing
    /// another round of inspection, run, and attention requests.
    func useLoadedSelection(
        worker: WorkerSummaryDTO,
        inspection: WorkerInspectResultDTO,
        runs: [WorkerInvocationDTO],
        attention: [WorkerInboxItemDTO]
    ) {
        if let index = workers.firstIndex(where: { $0.workerId == worker.workerId }) {
            workers[index] = worker
        } else {
            workers.append(worker)
        }
        selectedWorkerId = worker.workerId
        self.inspection = inspection
        self.runs = runs
        self.attention = attention
        selectedResults = attention
        webhookCredential = nil
        isLoadingSelection = false
        lastError = nil
    }

    /// Makes a known worker visible immediately while its detailed projection
    /// loads. This avoids blocking sheet presentation on an unrelated global
    /// dashboard refresh.
    func prepareSelection(_ worker: WorkerSummaryDTO) {
        if let index = workers.firstIndex(where: { $0.workerId == worker.workerId }) {
            workers[index] = worker
        } else {
            workers.append(worker)
        }
        selectedWorkerId = worker.workerId
        inspection = nil
        runs = []
        attention = []
        selectedResults = []
        webhookCredential = nil
        isLoadingSelection = true
        lastError = nil
    }

    func monitor(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        await monitor(
            scope: .activity,
            repository: repository,
            connectionState: connectionState
        )
    }

    func monitorResults(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        await monitor(
            scope: .results,
            repository: repository,
            connectionState: connectionState
        )
    }

    func monitorSummary(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        await monitor(
            scope: .summary,
            repository: repository,
            connectionState: connectionState
        )
    }

    private func monitor(
        scope: WorkerConsoleRefreshScope,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard connectionState.isConnected else { return }
        let invalidationName: Notification.Name = scope == .summary
            ? .workerLifecycleProjectionInvalidated
            : .workerRunProjectionInvalidated
        let invalidations = NotificationCenter.default.notifications(named: invalidationName)
        do {
            try await repository.ensureWorkerEventSubscriptions()
            monitoringError = nil
        } catch {
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                monitoringError = error.localizedDescription
            }
            return
        }

        for await _ in invalidations {
            guard !Task.isCancelled, connectionState.isConnected else { return }
            await requestRefresh(
                scope: scope,
                repository: repository,
                connectionState: connectionState
            )
        }
    }

    func setEnabled(
        _ enabled: Bool,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard let worker = selectedWorker else { return }
        await mutate(repository: repository, connectionState: connectionState) {
            _ = try await repository.setWorkerEnabled(
                enabled,
                workerId: worker.workerId,
                idempotencyKey: .userAction(enabled ? "worker.enable" : "worker.disable")
            )
        }
    }

    func stop(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard let worker = selectedWorker, worker.enabled, !worker.retired else { return }
        await mutate(repository: repository, connectionState: connectionState) {
            _ = try await repository.stopWorker(
                workerId: worker.workerId,
                idempotencyKey: .userAction("worker.stop")
            )
        }
    }

    func cancel(
        _ run: WorkerInvocationDTO,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard run.status == "queued" || run.status == "running" else { return }
        await mutate(repository: repository, connectionState: connectionState) {
            _ = try await repository.cancelWorkerInvocation(
                invocationId: run.invocationId,
                idempotencyKey: .userAction("worker.cancel")
            )
        }
    }

    func rollback(
        to version: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard let worker = selectedWorker else { return }
        await mutate(repository: repository, connectionState: connectionState) {
            let result = try await repository.rollbackWorker(
                workerId: worker.workerId,
                version: version,
                idempotencyKey: .userAction("worker.rollback")
            )
            webhookCredential = result.webhooks.first
        }
    }

    func retire(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard let worker = selectedWorker else { return }
        await mutate(repository: repository, connectionState: connectionState) {
            _ = try await repository.retireWorker(
                workerId: worker.workerId,
                idempotencyKey: .userAction("worker.retire")
            )
        }
    }

    func purge(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard let worker = selectedWorker else { return }
        await mutate(repository: repository, connectionState: connectionState) {
            _ = try await repository.purgeWorker(
                workerId: worker.workerId,
                idempotencyKey: .userAction("worker.purge")
            )
            selectedWorkerId = nil
            inspection = nil
        }
    }

    func setStopAll(
        _ stopped: Bool,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        await mutate(repository: repository, connectionState: connectionState) {
            _ = try await repository.setWorkersStopped(
                stopped,
                idempotencyKey: .userAction(stopped ? "worker.stopAll" : "worker.resumeAll")
            )
            stopAll = stopped
        }
    }

    func rotateWebhook(
        triggerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard let worker = selectedWorker else { return }
        await mutate(repository: repository, connectionState: connectionState) {
            webhookCredential = try await repository.rotateWorkerWebhook(
                workerId: worker.workerId,
                triggerId: triggerId,
                idempotencyKey: .userAction("worker.webhook.rotate")
            )
        }
    }

    private func loadWorker(
        _ workerId: String,
        repository: any WorkerKernelRepository,
        projectionTicket: Int? = nil
    ) async throws {
        let inspectionRequest = Task { @MainActor in
            try await repository.inspectWorker(workerId)
        }
        let runsRequest = Task { @MainActor in
            try await repository.workerRuns(workerId: workerId, limit: 20)
        }
        let resultsRequest = Task { @MainActor in
            try await repository.workerInbox(
                workerId: workerId,
                limit: 20,
                offset: nil,
                attentionOnly: false
            )
        }
        let (loadedInspection, loadedRuns, loadedResults): (
            WorkerInspectResultDTO,
            WorkerRunsResultDTO,
            WorkerInboxResultDTO
        )
        do {
            (loadedInspection, loadedRuns, loadedResults) = try await withTaskCancellationHandler {
                try await (
                    inspectionRequest.value,
                    runsRequest.value,
                    resultsRequest.value
                )
            } onCancel: {
                inspectionRequest.cancel()
                runsRequest.cancel()
                resultsRequest.cancel()
            }
        } catch {
            inspectionRequest.cancel()
            runsRequest.cancel()
            resultsRequest.cancel()
            throw error
        }
        try Task.checkCancellation()
        if let projectionTicket,
           projectionTicket != projectionGeneration {
            throw CancellationError()
        }
        inspection = loadedInspection
        runs = loadedRuns.runs
        selectedResults = loadedResults.items
        attention = loadedResults.items.filter {
            WorkerConsolePresentation.resultDisposition($0) == .needsAttention
        }
    }

    private func mutate(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState,
        operation: () async throws -> Void
    ) async {
        guard connectionState.isConnected else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await operation()
            await refreshSummary(
                repository: repository,
                connectionState: connectionState
            )
            if selectedWorkerId != nil {
                await reconcileSelection(repository: repository)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func prettyJSON(_ value: AnyCodable) -> String {
        guard JSONSerialization.isValidJSONObject(value.value),
              let data = try? JSONSerialization.data(
                withJSONObject: value.value,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return String(describing: value.value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func appendUnique<Element>(
        _ incoming: [Element],
        to existing: inout [Element],
        id: KeyPath<Element, String>
    ) {
        var identifiers = Set(existing.map { $0[keyPath: id] })
        existing.append(contentsOf: incoming.filter { identifiers.insert($0[keyPath: id]).inserted })
    }
}

extension Notification.Name {
    /// Invalidation only: consumers re-read the authoritative durable graph.
    /// No worker execution state is carried in the notification.
    static let workerRunProjectionInvalidated = Notification.Name(
        "tron.worker-run-projection-invalidated"
    )

    /// A worker was activated, disabled, retired, restored, or otherwise
    /// changed ownership metadata. Client-action availability observes this
    /// narrow lane instead of refreshing for every ordinary invocation.
    static let workerLifecycleProjectionInvalidated = Notification.Name(
        "tron.worker-lifecycle-projection-invalidated"
    )
}
