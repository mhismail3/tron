import Foundation

/// Manages deep-link navigation and session lifecycle actions for ContentView.
/// Keeps ContentView focused on layout and presentation.
@MainActor
final class ContentViewCoordinator {
    enum SessionPublicationError: LocalizedError {
        case coordinatorUnavailable
        case sessionNotPublished
        case draftNotPersisted

        var errorDescription: String? {
            switch self {
            case .coordinatorUnavailable:
                "The session coordinator is not ready. Try again."
            case .sessionNotPublished:
                "The session was created, but its local index could not be refreshed."
            case .draftNotPersisted:
                "The session was created, but its prepared draft could not be saved. Try again."
            }
        }
    }

    private let dependencies: DependencyContainer

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }

    init(dependencies: DependencyContainer) {
        self.dependencies = dependencies
    }

    // MARK: - Deep Link Handling

    /// Handles deep link navigation to a session.
    /// Returns the scroll target if the session exists locally, or refreshes the
    /// authoritative session index before mounting canonical reconstruction.
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
                await manager.refreshSessionList()
                guard manager.sessionExists(sessionId) else {
                    TronLogger.shared.error(
                        "Deep-linked session was not present in the authoritative session list",
                        category: .notification
                    )
                    return
                }
                onNavigate(sessionId, scrollTarget)
            }
        }
    }

    // MARK: - Session Operations

    /// Publish a server-created session into the local projection before any
    /// navigation can construct its ChatView. If the direct cache write fails,
    /// reconcile from server truth once before reporting a recoverable error.
    func publishCreatedSession(_ created: NewSessionCreated) async throws -> String {
        do {
            try await eventStoreManager.cacheNewSession(
                sessionId: created.sessionId,
                workspaceId: created.workspaceId,
                model: created.model,
                workingDirectory: created.workingDirectory
            )
        } catch {
            TronLogger.shared.warning(
                "Direct new-session publication failed; reconciling server truth: \(error.localizedDescription)",
                category: .session
            )
            await eventStoreManager.refreshSessionList()
        }
        guard eventStoreManager.sessionExists(created.sessionId) else {
            throw SessionPublicationError.sessionNotPublished
        }
        return created.sessionId
    }

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

    /// Create and publish a visible chat, durably persist its prepared draft,
    /// and only then allow navigation to mount ChatView.
    ///
    /// Result handoffs use the kernel's atomic session-plus-grant operation;
    /// worker and artifact handoffs use ordinary session creation. All sources
    /// converge on the same local draft boundary.
    func createSession(
        for request: AgentSessionHandoffRequest,
        selectedSessionId: String?
    ) async throws -> String {
        let workspace = resolveQuickSessionWorkspace(
            setting: dependencies.quickSessionWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: selectedSessionId,
            sessions: eventStoreManager.sessions,
            sortedSessions: eventStoreManager.sortedSessions
        )
        let model = dependencies.defaultModel
        let created: NewSessionCreated
        if let invocationId = request.resultInvocationId {
            let result = try await dependencies.workerKernelRepository
                .createWorkerResultHandoff(
                    invocationId: invocationId,
                    workingDirectory: workspace,
                    model: model,
                    title: String(request.title.prefix(120)),
                    idempotencyKey: EngineIdempotencyKey(
                        rawValue: "ios:user-action:agent-session-handoff:\(request.id.uuidString)"
                    )
                )
            created = NewSessionCreated(
                sessionId: result.sessionId,
                workspaceId: result.workspaceId,
                model: result.model,
                workingDirectory: result.workingDirectory
            )
        } else {
            let result = try await dependencies.sessionRepository.create(
                workingDirectory: workspace,
                model: model,
                idempotencyKey: EngineIdempotencyKey(
                    rawValue: "ios:user-action:agent-session-handoff:\(request.id.uuidString)"
                )
            )
            created = NewSessionCreated(
                sessionId: result.sessionId,
                workspaceId: workspace,
                model: result.model,
                workingDirectory: workspace
            )
        }

        let sessionId = try await publishCreatedSession(created)
        let draft = InputBarState()
        draft.text = request.prompt
        draft.attachments = request.attachments
        await dependencies.draftStore.saveImmediately(
            sessionId: sessionId,
            inputBarState: draft
        )
        let verification = InputBarState()
        guard await dependencies.draftStore.loadDraft(
            sessionId: sessionId,
            into: verification
        ), verification.text == request.prompt,
           verification.attachments == request.attachments else {
            throw SessionPublicationError.draftNotPersisted
        }
        return sessionId
    }
}
