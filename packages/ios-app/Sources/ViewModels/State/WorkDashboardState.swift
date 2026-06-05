import Foundation

@MainActor
protocol AgentWorkSnapshotClient: AnyObject {
    func workSnapshot(sessionId: String?, workspaceId: String?, limit: Int) async throws -> WorkSnapshotDTO
}

extension AgentClient: AgentWorkSnapshotClient {}

@MainActor
@Observable
final class WorkDashboardState {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let client: AgentWorkSnapshotClient
    private let limit: Int

    private(set) var loadState: LoadState = .idle
    private(set) var snapshot: WorkSnapshotDTO?

    var hasBlockedWork: Bool {
        !(snapshot?.guardrails.isEmpty ?? true)
    }

    init(client: AgentWorkSnapshotClient, limit: Int = 12) {
        self.client = client
        self.limit = limit
    }

    convenience init(engineClient: EngineClient, limit: Int = 12) {
        self.init(client: engineClient.agent, limit: limit)
    }

    func refresh(sessionId: String? = nil, workspaceId: String? = nil) async {
        loadState = .loading
        do {
            snapshot = try await client.workSnapshot(
                sessionId: sessionId,
                workspaceId: workspaceId,
                limit: limit
            )
            loadState = .loaded
        } catch {
            snapshot = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    func recentMilestonesForWorker(_ worker: WorkWorkerDTO) -> [WorkMilestoneDTO] {
        snapshot?.recentMilestones.filter { milestone in
            milestone.workerId == worker.workerId || milestone.workerId == worker.runId
        } ?? []
    }

    func guardrailsForWorker(_ worker: WorkWorkerDTO) -> [WorkGuardrailDTO] {
        let functionIds = Set(worker.abilities.map(\.functionId))
        return snapshot?.guardrails.filter { guardrail in
            guardrail.functionId.map(functionIds.contains) ?? false
        } ?? []
    }
}
