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
    var isMutating = false
    var stopAll = false
    var lastError: String?

    var selectedWorker: WorkerSummaryDTO? {
        workers.first { $0.workerId == selectedWorkerId }
    }

    var healthyCount: Int {
        workers.filter { $0.enabled && $0.health == "healthy" }.count
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
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
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
        do {
            try await loadWorker(workerId, repository: repository)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func monitor(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        var cursors: [String: EngineStreamCursor] = [:]
        let topics = ["worker.lifecycle", "worker.invocations"]
        while !Task.isCancelled && connectionState.isConnected {
            var changed = false
            for topic in topics {
                do {
                    let page = try await repository.pollWorkerEvents(
                        topic: topic,
                        cursor: cursors[topic]
                    )
                    if let next = page.nextCursor {
                        cursors[topic] = EngineStreamCursor(rawValue: next)
                    }
                    changed = changed || !page.events.isEmpty
                } catch {
                    lastError = error.localizedDescription
                }
            }
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
