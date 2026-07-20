import Foundation

@Observable
@MainActor
final class WorkerConsoleViewModel {
    var workers: [WorkerSummaryDTO] = []
    var selectedWorkerId: String?
    var inspection: WorkerInspectResultDTO?
    var runs: [WorkerInvocationDTO] = []
    var inbox: [WorkerInboxItemDTO] = []
    var invocationInput = "{}"
    var invocationResult: String?
    var webhookCredential: WorkerWebhookCredentialDTO?
    var isRefreshing = false
    var isLoadingSelection = false
    var isMutating = false
    var hasLoaded = false
    var stopAll = false
    var lastError: String?
    var monitoringError: String?

    var selectedWorker: WorkerSummaryDTO? {
        workers.first { $0.workerId == selectedWorkerId }
    }

    var healthyCount: Int {
        workers.filter { $0.enabled && $0.health == "healthy" }.count
    }

    var enabledCount: Int {
        workers.filter { $0.enabled && !$0.retired }.count
    }

    var attentionCount: Int {
        workers.filter {
            WorkerConsolePresentation.status(for: $0).kind == .needsAttention
        }.count
    }

    var invocationJSONIsValid: Bool {
        (try? Self.decodeJSON(invocationInput)) != nil
    }

    var canInvokeSelectedWorker: Bool {
        guard let selectedWorker else { return false }
        return selectedWorker.enabled
            && !selectedWorker.retired
            && !isMutating
            && invocationJSONIsValid
    }

    func refresh(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard connectionState.isConnected else {
            workers = []
            inspection = nil
            runs = []
            inbox = []
            hasLoaded = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            hasLoaded = true
        }
        do {
            let result = try await repository.workers(includeRetired: true)
            workers = result.workers
            stopAll = result.stopAll
            if let selectedWorkerId,
               workers.contains(where: { $0.workerId == selectedWorkerId }) {
                try await loadWorker(selectedWorkerId, repository: repository)
            } else {
                selectedWorkerId = nil
                inspection = nil
                runs = []
                inbox = []
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func select(_ workerId: String, repository: any WorkerKernelRepository) async {
        selectedWorkerId = workerId
        inspection = nil
        runs = []
        inbox = []
        invocationResult = nil
        webhookCredential = nil
        isLoadingSelection = true
        defer { isLoadingSelection = false }
        do {
            try await loadWorker(workerId, repository: repository)
            invocationInput = WorkerConsolePresentation.invocationTemplate(
                from: inspection?.bundle["inputSchema"]
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func monitor(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        let topics = ["worker.lifecycle", "worker.invocations"]
        // Topic polling is historical replay. Unlike live subscribe, the engine
        // requires an explicit cursor, so every topic starts at the durable origin.
        var cursors = Dictionary(
            uniqueKeysWithValues: topics.map { ($0, EngineStreamCursor(rawValue: 0)) }
        )
        while !Task.isCancelled && connectionState.isConnected {
            var changed = false
            var pollingError: String?
            for topic in topics {
                do {
                    let page = try await repository.pollWorkerEvents(
                        topic: topic,
                        cursor: cursors[topic] ?? EngineStreamCursor(rawValue: 0)
                    )
                    if let next = page.nextCursor {
                        cursors[topic] = EngineStreamCursor(rawValue: next)
                    }
                    changed = changed || !page.events.isEmpty
                } catch {
                    pollingError = error.localizedDescription
                }
            }
            monitoringError = pollingError
            if changed {
                await refresh(repository: repository, connectionState: connectionState)
            }
            try? await Task.sleep(for: .seconds(1))
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

    func invoke(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard let worker = selectedWorker else { return }
        await mutate(repository: repository, connectionState: connectionState) {
            let input = try Self.decodeJSON(invocationInput)
            let result = try await repository.invokeWorker(
                workerId: worker.workerId,
                input: input,
                idempotencyKey: .userAction("worker.invoke")
            )
            invocationResult = Self.prettyJSON(AnyCodable(result.output?.value ?? [
                "status": result.status,
                "invocationId": result.invocationId,
            ]))
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
        repository: any WorkerKernelRepository
    ) async throws {
        inspection = try await repository.inspectWorker(workerId)
        runs = try await repository.workerRuns(workerId: workerId, limit: 100).runs
        inbox = try await repository.workerInbox(workerId: workerId, limit: 100).items
    }

    private func mutate(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState,
        operation: () async throws -> Void
    ) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await operation()
            await refresh(repository: repository, connectionState: connectionState)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func decodeJSON(_ text: String) throws -> AnyCodable {
        let data = Data(text.utf8)
        return AnyCodable(try JSONSerialization.jsonObject(with: data))
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
}
