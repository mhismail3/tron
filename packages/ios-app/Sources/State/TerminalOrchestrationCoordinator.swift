import Foundation
import Observation

@MainActor
@Observable
final class TerminalCoordinator {
    struct Retirement {
        fileprivate let cleanupTasks: [Task<Void, Never>]
    }

    private struct ListParams: Codable, Sendable { let sessionId: String }
    private struct ListResponse: Decodable, Sendable { let terminals: [TerminalSummary] }
    private struct OpenParams: Codable, Sendable {
        let sessionId: String
        let columns: Int
        let rows: Int
        let commandId: String
    }
    private struct OpenReplay: Codable, Sendable {
        let terminal: TerminalSummary
        let chunks: [TerminalChunk]
        let reset: Bool
    }
    private struct OpenResponse: Codable, Sendable {
        let terminal: TerminalSummary
        let replay: OpenReplay
    }
    private struct AttachParams: Codable, Sendable {
        let terminalId: String
        let afterSequence: Int
    }
    private struct AttachResponse: Decodable, Sendable {
        let terminal: TerminalSummary
        let chunks: [TerminalChunk]
        let reset: Bool
    }
    private struct DetachParams: Codable, Sendable { let terminalId: String }
    private struct DetachResponse: Decodable, Sendable { let detached: Bool }
    private struct WriteParams: Codable, Sendable {
        let terminalId: String
        let writeId: String
        let data: String
        let commandId: String
    }
    private struct WriteResponse: Codable, Sendable { let written: Bool }
    private struct ResizeParams: Codable, Sendable {
        let terminalId: String
        let columns: Int
        let rows: Int
        let commandId: String
    }
    private struct ResizeResponse: Codable, Sendable { let resized: Bool }
    private struct TerminateParams: Codable, Sendable {
        let terminalId: String
        let commandId: String
    }
    private struct TerminateResponse: Codable, Sendable { let terminated: Bool }

    private let client: GatewayClient
    private let lifecycle: GatewayLifecycleCoordinator
    private let mutationExecutor: ConfirmedMutationExecutor
    private let uuidSource: UUIDSource
    private let performanceSignposts: any PerformanceSignposting
    private let installedSubscriptionToken: @MainActor (String) -> String?

    private struct CleanupFlight {
        let token: UInt64
        let task: Task<Void, Never>
    }

    private var reducer = TerminalReducer()
    private var cleanupGeneration: UInt64 = 0
    private var cleanupTasks: [TerminalDetachClaim: CleanupFlight] = [:]

    init(
        client: GatewayClient,
        lifecycle: GatewayLifecycleCoordinator,
        mutationExecutor: ConfirmedMutationExecutor,
        uuidSource: UUIDSource,
        performanceSignposts: any PerformanceSignposting,
        installedSubscriptionToken: @escaping @MainActor (String) -> String?
    ) {
        self.client = client
        self.lifecycle = lifecycle
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
        self.performanceSignposts = performanceSignposts
        self.installedSubscriptionToken = installedSubscriptionToken
    }

    func beginPresentation(sessionID: String) -> TerminalPresentationTarget {
        reducer.beginPresentation(sessionID: sessionID)
    }

    func beginIntent(for target: TerminalPresentationTarget) -> TerminalPresentationIntent? {
        guard let transition = reducer.beginIntent(for: target) else { return nil }
        scheduleDetaches(transition.detached)
        return transition.intent
    }

    func closePresentation(_ target: TerminalPresentationTarget) {
        scheduleDetaches(reducer.revokePresentation(target))
    }

    func owns(_ intent: TerminalPresentationIntent) -> Bool { reducer.owns(intent) }
    func replay(for terminalID: String) -> TerminalReplayProjection { reducer.replay(for: terminalID) }
    func hasExited(_ terminalID: String) -> Bool { reducer.hasExited(terminalID) }

    func list(intent: TerminalPresentationIntent) async throws -> [TerminalSummary] {
        let sessionID = intent.presentation.sessionID
        let admission = lifecycle.admission
        let subscriptionToken = installedSubscriptionToken(sessionID)
        guard let admission,
              reducer.owns(intent),
              subscriptionToken != nil else {
            throw GatewayFailure(
                code: "sync_failed",
                message: "Open the session before listing terminals.",
                retryable: true,
                details: nil
            )
        }
        let request = Task {
            try await client.request("terminal.list", ListParams(sessionId: sessionID)) as ListResponse
        }
        let response = try await request.value
        try lifecycle.requireConnection(admission)
        guard reducer.owns(intent),
              installedSubscriptionToken(sessionID) == subscriptionToken,
              response.terminals.allSatisfy({ $0.sessionId == sessionID }) else {
            throw CancellationError()
        }
        reducer.installInventory(response.terminals, sessionID: sessionID)
        return response.terminals
    }

    func open(
        intent: TerminalPresentationIntent,
        columns: Int,
        rows: Int
    ) async throws -> TerminalSummary {
        let sessionID = intent.presentation.sessionID
        let subscriptionToken = installedSubscriptionToken(sessionID)
        guard let admission = lifecycle.admission,
              let connectionID = admission.connectionID,
              subscriptionToken != nil,
              let lease = reducer.beginOpen(intent: intent, connectionID: connectionID) else {
            throw CancellationError()
        }
        return try await measureAttachReplay {
            let commandID = uuidSource.next().uuidString
            let params = OpenParams(
                sessionId: sessionID,
                columns: columns,
                rows: rows,
                commandId: commandID
            )
            let request = Task {
                try await mutationExecutor.perform(method: "terminal.open", commandID: commandID) {
                    try await client.request("terminal.open", params)
                } as OpenResponse
            }
            let response: OpenResponse
            do {
                response = try await request.value
            } catch {
                reducer.finish(lease)
                throw error
            }
            let currentAdmission = lifecycle.admission
            let currentConnectionID = currentAdmission?.connectionID
            switch TerminalReducer.openResponseDisposition(
                requestLifecycleGeneration: admission.generation,
                requestConnectionID: connectionID,
                currentLifecycleGeneration: currentAdmission?.generation,
                currentConnectionID: currentConnectionID
            ) {
            case .install:
                guard installedSubscriptionToken(sessionID) == subscriptionToken else {
                    reducer.finish(lease)
                    scheduleDetachIfUnowned(TerminalDetachClaim(
                        terminalID: response.terminal.id,
                        connectionID: connectionID
                    ))
                    throw CancellationError()
                }
            case .reattach:
                reducer.finish(lease)
                guard reducer.owns(intent),
                      let currentAdmission,
                      currentConnectionID != nil,
                      installedSubscriptionToken(sessionID) != nil else {
                    if let currentConnectionID {
                        scheduleDetachIfUnowned(TerminalDetachClaim(
                            terminalID: response.terminal.id,
                            connectionID: currentConnectionID
                        ))
                    }
                    throw CancellationError()
                }
                return try await beginAttach(
                    response.terminal.id,
                    after: 0,
                    intent: intent,
                    admission: currentAdmission
                )
            case .discard:
                reducer.finish(lease)
                throw CancellationError()
            }
            guard !Task.isCancelled,
                  lifecycle.admits(admission),
                  let installation = reducer.installReplay(
                    response.replay.chunks,
                    terminal: response.terminal,
                    reset: true,
                    after: 0,
                    lease: lease
                  ) else {
                reducer.finish(lease)
                scheduleDetachIfUnowned(TerminalDetachClaim(
                    terminalID: response.terminal.id,
                    connectionID: connectionID
                ))
                throw CancellationError()
            }
            if installation.requiresReconciliation { reconcile(response.terminal.id) }
            return (response.terminal, PerformanceMetrics(itemCount: installation.admittedCount))
        }
    }

    func attach(
        _ terminalID: String,
        after: Int,
        intent: TerminalPresentationIntent
    ) async throws -> TerminalSummary {
        guard let admission = lifecycle.admission else { throw CancellationError() }
        return try await measureAttachReplay {
            try await beginAttach(
                terminalID,
                after: after,
                intent: intent,
                admission: admission
            )
        }
    }

    func write(
        _ terminalID: String,
        data: String,
        intent: TerminalPresentationIntent
    ) async throws {
        guard reducer.owns(intent) else { throw CancellationError() }
        let identity = uuidSource.next().uuidString
        let params = WriteParams(
            terminalId: terminalID,
            writeId: identity,
            data: data,
            commandId: identity
        )
        let _: WriteResponse = try await mutationExecutor.perform(
            method: "terminal.write",
            commandID: identity
        ) {
            try await client.request("terminal.write", params)
        }
    }

    func resizeImmediately(
        _ terminalID: String,
        columns: Int,
        rows: Int,
        intent: TerminalPresentationIntent
    ) async throws {
        guard reducer.owns(intent) else { throw CancellationError() }
        let commandID = uuidSource.next().uuidString
        let params = ResizeParams(
            terminalId: terminalID,
            columns: columns,
            rows: rows,
            commandId: commandID
        )
        let _: ResizeResponse = try await mutationExecutor.perform(
            method: "terminal.resize",
            commandID: commandID
        ) {
            try await client.request("terminal.resize", params)
        }
    }

    func terminate(_ terminalID: String, intent: TerminalPresentationIntent) async throws {
        guard reducer.owns(intent) else { throw CancellationError() }
        let commandID = uuidSource.next().uuidString
        let params = TerminateParams(terminalId: terminalID, commandId: commandID)
        let _: TerminateResponse = try await mutationExecutor.perform(
            method: "terminal.terminate",
            commandID: commandID
        ) {
            try await client.request("terminal.terminate", params)
        }
    }

    func admit(
        _ event: PreparedTerminalEvent,
        connectionID: Int,
        exitedAt: @autoclosure () -> String
    ) {
        if case .reconcile(let terminalID) = reducer.admit(
            event,
            connectionID: connectionID,
            exitedAt: exitedAt()
        ) {
            reconcile(terminalID)
        }
    }

    func reattach(admission: GatewayLifecycleCoordinator.Admission) async {
        guard lifecycle.admits(admission),
              let connectionID = admission.connectionID else { return }
        for terminalID in reducer.attachedTerminalIDs() {
            await cancelCleanup(TerminalDetachClaim(
                terminalID: terminalID,
                connectionID: connectionID
            ))
            guard let lease = reducer.beginReattachment(
                terminalID: terminalID,
                connectionID: connectionID
            ) else { continue }
            let after = reducer.replay(for: terminalID).chunks.last?.sequence ?? 0
            _ = try? await measureAttachReplay {
                try await performAttach(
                    terminalID,
                    after: after,
                    lease: lease,
                    admission: admission
                )
            }
        }
    }

    func beginRetirement() -> Retirement {
        let tasks = cleanupTasks.values.map(\.task)
        cleanupTasks.removeAll()
        tasks.forEach { $0.cancel() }
        reducer.clear()
        return Retirement(cleanupTasks: tasks)
    }

    func finishRetirement(_ retirement: Retirement) async {
        for task in retirement.cleanupTasks { await task.value }
    }

    private func beginAttach(
        _ terminalID: String,
        after: Int,
        intent: TerminalPresentationIntent,
        admission: GatewayLifecycleCoordinator.Admission
    ) async throws -> (TerminalSummary, PerformanceMetrics) {
        guard let connectionID = admission.connectionID else { throw CancellationError() }
        await cancelCleanup(TerminalDetachClaim(
            terminalID: terminalID,
            connectionID: connectionID
        ))
        guard lifecycle.admits(admission),
              let lease = reducer.beginAttachment(
                terminalID: terminalID,
                intent: intent,
                connectionID: connectionID
              ) else { throw CancellationError() }
        return try await performAttach(
            terminalID,
            after: after,
            lease: lease,
            admission: admission
        )
    }

    private func performAttach(
        _ terminalID: String,
        after: Int,
        lease: TerminalAttachmentLease,
        admission: GatewayLifecycleCoordinator.Admission
    ) async throws -> (TerminalSummary, PerformanceMetrics) {
            let request = Task {
                try await client.request(
                    "terminal.attach",
                    AttachParams(terminalId: terminalID, afterSequence: after)
                ) as AttachResponse
            }
            let response: AttachResponse
            do {
                response = try await request.value
            } catch {
                reducer.finish(lease)
                scheduleDetachIfUnowned(TerminalDetachClaim(
                    terminalID: terminalID,
                    connectionID: lease.connectionID
                ))
                throw error
            }
            guard !Task.isCancelled,
                  lifecycle.admits(admission),
                  let installation = reducer.installReplay(
                    response.chunks,
                    terminal: response.terminal,
                    reset: response.reset,
                    after: after,
                    lease: lease
                  ) else {
                reducer.finish(lease)
                scheduleDetachIfUnowned(TerminalDetachClaim(
                    terminalID: terminalID,
                    connectionID: lease.connectionID
                ))
                if reducer.requiresReconciliation(terminalID) { reconcile(terminalID) }
                throw CancellationError()
            }
            if installation.requiresReconciliation { reconcile(response.terminal.id) }
        return (response.terminal, PerformanceMetrics(itemCount: installation.admittedCount))
    }

    private func scheduleDetaches(_ claims: [TerminalDetachClaim]) {
        for claim in claims { scheduleDetachIfUnowned(claim) }
    }

    private func scheduleDetachIfUnowned(_ claim: TerminalDetachClaim) {
        guard let admission = lifecycle.admission,
              admission.connectionID == claim.connectionID else { return }
        cleanupTasks[claim]?.task.cancel()
        cleanupGeneration &+= 1
        let token = cleanupGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.cleanupTasks[claim]?.token == token {
                    self.cleanupTasks.removeValue(forKey: claim)
                }
            }
            guard self.lifecycle.admits(admission),
                  !self.reducer.hasCurrentInterest(
                    in: claim.terminalID,
                    connectionID: claim.connectionID
                  ) else { return }
            let _: DetachResponse? = try? await self.client.request(
                "terminal.detach",
                DetachParams(terminalId: claim.terminalID)
            )
        }
        cleanupTasks[claim] = CleanupFlight(token: token, task: task)
    }

    private func cancelCleanup(_ claim: TerminalDetachClaim) async {
        guard let flight = cleanupTasks.removeValue(forKey: claim) else { return }
        flight.task.cancel()
        await flight.task.value
    }

    private func reconcile(_ terminalID: String) {
        guard let admission = lifecycle.admission,
              let connectionID = admission.connectionID,
              let lease = reducer.beginReconciliation(
                terminalID: terminalID,
                connectionID: connectionID
              ) else { return }
        let after = reducer.replay(for: terminalID).chunks.last?.sequence ?? 0
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.measureAttachReplay {
                try await self.performAttach(
                    terminalID,
                    after: after,
                    lease: lease,
                    admission: admission
                )
            }
        }
    }

    private func measureAttachReplay<Value>(
        body: () async throws -> (Value, PerformanceMetrics)
    ) async throws -> Value {
        let interval = performanceSignposts.begin(.terminalAttachReplay)
        do {
            let (value, metrics) = try await body()
            performanceSignposts.end(interval, result: .success, metrics: metrics)
            return value
        } catch {
            performanceSignposts.end(
                interval,
                result: PerformanceResult.forFailure(error),
                metrics: .none
            )
            throw error
        }
    }
}
