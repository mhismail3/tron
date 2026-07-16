import Foundation

/// Manages deep-link navigation and session lifecycle actions for ContentView.
/// Keeps ContentView focused on layout and presentation.
@MainActor
final class ContentViewCoordinator {
    private let dependencies: DependencyContainer

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }

    init(dependencies: DependencyContainer) {
        self.dependencies = dependencies
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
            setting: dependencies.quickSessionWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: selectedSessionId,
            sessions: eventStoreManager.sessions,
            sortedSessions: eventStoreManager.sortedSessions
        )

        Task {
            do {
                let result = try await dependencies.sessionRepository.create(
                    workingDirectory: workspace,
                    model: dependencies.defaultModel,
                    idempotencyKey: .userAction("session.create")
                )

                try await eventStoreManager.cacheNewSession(
                    sessionId: result.sessionId,
                    workspaceId: workspace,
                    model: result.model,
                    workingDirectory: workspace,
                    source: nil,
                    profile: nil
                )

                await MainActor.run {
                    onCreated(result.sessionId)
                }
            } catch {
                TronLogger.shared.error("Failed to create quick session: \(error)", category: .session)
            }
        }
    }
}
