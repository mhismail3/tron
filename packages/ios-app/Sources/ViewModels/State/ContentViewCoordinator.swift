import Foundation

/// Manages connection state, workspace validation, and session lifecycle for ContentView.
/// Keeps ContentView focused on layout and presentation.
@Observable
@MainActor
final class ContentViewCoordinator {
    private let rpcClient: RPCClient
    private let eventStoreManager: EventStoreManager
    private let quickSessionWorkspaceSetting: String
    private let defaultModel: String

    // MARK: - State

    /// Tracks which sessions have deleted workspaces
    var workspaceDeletedForSession: [String: Bool] = [:]
    var isValidatingWorkspace = false

    init(
        rpcClient: RPCClient,
        eventStoreManager: EventStoreManager,
        quickSessionWorkspaceSetting: String,
        defaultModel: String
    ) {
        self.rpcClient = rpcClient
        self.eventStoreManager = eventStoreManager
        self.quickSessionWorkspaceSetting = quickSessionWorkspaceSetting
        self.defaultModel = defaultModel
    }

    // MARK: - Connection State Handling

    /// Called when connection state transitions to connected.
    /// Refreshes session list and re-validates the current session's workspace.
    func handleConnectionEstablished(selectedSessionId: String?) {
        eventStoreManager.startDashboardPolling()

        Task {
            await eventStoreManager.refreshSessionList()
        }

        if let sessionId = selectedSessionId {
            validateWorkspace(for: sessionId)
        }
    }

    /// Called when server settings change. Clears cached workspace states and refreshes sessions.
    func handleServerSettingsChanged() {
        workspaceDeletedForSession = [:]
        Task {
            await eventStoreManager.refreshSessionList()
        }
    }

    // MARK: - Session Selection

    /// Handles session selection: persists active session and validates workspace.
    func handleSessionSelection(_ sessionId: String?) {
        guard let id = sessionId else { return }
        eventStoreManager.setActiveSession(id)
        validateWorkspace(for: id)
    }

    // MARK: - Deep Link Handling

    /// Handles deep link navigation to a session.
    /// Returns the scroll target if session exists locally, or syncs from server first.
    func handleDeepLink(
        sessionId: String?,
        scrollTarget: ScrollTarget?,
        onNavigate: @escaping (_ sessionId: String, _ scrollTarget: ScrollTarget?) -> Void
    ) {
        guard let sessionId = sessionId else { return }

        if eventStoreManager.sessionExists(sessionId) {
            onNavigate(sessionId, scrollTarget)
        } else {
            let manager = eventStoreManager
            Task {
                do {
                    try await manager.syncSessionEvents(sessionId: sessionId)
                    await MainActor.run {
                        onNavigate(sessionId, scrollTarget)
                    }
                } catch {
                    TronLogger.shared.error("Failed to sync session for deep link: \(error)", category: .notification)
                }
            }
        }
    }

    // MARK: - Session Operations

    func deleteSession(_ sessionId: String, isSelected: Bool, onSelectNext: @escaping (String?) -> Void) {
        let manager = eventStoreManager
        Task {
            do {
                try await manager.deleteSession(sessionId)
            } catch {
                TronLogger.shared.error("Failed to delete session: \(error)", category: .session)
            }

            if isSelected {
                await MainActor.run {
                    onSelectNext(manager.sessions.first?.id)
                }
            }
        }
    }

    func createQuickSession(
        selectedSessionId: String?,
        onCreated: @escaping (String) -> Void
    ) {
        let workspace = resolveQuickSessionWorkspace(
            setting: quickSessionWorkspaceSetting,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: selectedSessionId,
            sessions: eventStoreManager.sessions,
            sortedSessions: eventStoreManager.sortedSessions
        )

        Task {
            do {
                let result = try await rpcClient.session.create(
                    workingDirectory: workspace,
                    model: defaultModel
                )

                try eventStoreManager.cacheNewSession(
                    sessionId: result.sessionId,
                    workspaceId: workspace,
                    model: result.model,
                    workingDirectory: workspace
                )

                await MainActor.run {
                    onCreated(result.sessionId)
                }
            } catch {
                TronLogger.shared.error("Failed to create quick session: \(error)", category: .session)
            }
        }
    }

    // MARK: - Private

    private func validateWorkspace(for sessionId: String) {
        guard let session = eventStoreManager.sessions.first(where: { $0.id == sessionId }) else {
            return
        }

        let manager = eventStoreManager
        let workingDir = session.workingDirectory
        Task {
            isValidatingWorkspace = true
            if let pathExists = await manager.validateWorkspacePath(workingDir) {
                workspaceDeletedForSession[sessionId] = !pathExists
            }
            isValidatingWorkspace = false
        }
    }
}
