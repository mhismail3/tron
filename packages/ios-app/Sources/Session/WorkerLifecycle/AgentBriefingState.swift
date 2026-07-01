import Foundation

enum AgentBriefingLoadState: Equatable, Sendable {
    case unavailable
    case loading
    case loaded(AgentBriefingOverviewDTO)
    case degraded(String)

    var overview: AgentBriefingOverviewDTO? {
        if case .loaded(let overview) = self { return overview }
        return nil
    }
}

@Observable
@MainActor
final class AgentBriefingViewModel {
    var state: AgentBriefingLoadState = .unavailable
    var isRefreshing = false

    func refresh(
        repository: any WorkerLifecycleRepository,
        sessionId: String?,
        workspaceId: String?,
        connectionState: ConnectionState
    ) async {
        guard connectionState.isConnected else {
            state = .unavailable
            return
        }
        guard sessionId != nil || workspaceId != nil else {
            state = .degraded("Open a session to scope the briefing.")
            return
        }
        isRefreshing = true
        state = state.overview == nil ? .loading : state
        defer { isRefreshing = false }
        do {
            let overview = try await repository.agentBriefingOverview(
                limit: 12,
                sessionId: sessionId,
                workspaceId: workspaceId
            )
            state = .loaded(overview)
        } catch {
            state = .degraded(error.localizedDescription)
        }
    }
}

enum AgentBriefingStatusTone: Equatable {
    case active
    case waiting
    case blocked
    case recorded

    init(_ status: String) {
        switch status.lowercased() {
        case "active", "running":
            self = .active
        case "waiting", "pending_review":
            self = .waiting
        case "blocked", "failed", "degraded":
            self = .blocked
        default:
            self = .recorded
        }
    }
}
