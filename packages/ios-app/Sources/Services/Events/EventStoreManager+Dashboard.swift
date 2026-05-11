import Foundation

// MARK: - Dashboard & Processing State

extension EventStoreManager {

    /// Mark a session as processing (agent is thinking)
    func setSessionProcessing(_ sessionId: String, isProcessing: Bool) {
        if isProcessing {
            processingSessionIds.insert(sessionId)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await engineClient.ensureSessionEventSubscription(sessionId: sessionId, workspaceId: nil)
                    logger.debug(
                        "Session projection subscribed to live events for processing session \(String(sessionId.prefix(12)))...",
                        category: .events
                    )
                } catch {
                    logger.warning(
                        "Session projection could not subscribe to live events for \(String(sessionId.prefix(12)))...: \(error.localizedDescription)",
                        category: .events
                    )
                }
            }
        } else {
            processingSessionIds.remove(sessionId)
        }

        // Update the session's processing flag
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { $0.isProcessing = isProcessing }
        }
    }

    /// Seed processingSessionIds from server-provided isRunning flags on sessions.
    /// Called after session list refresh to sync processing state from the server.
    func seedProcessingStateFromSessions() {
        let runningIds = Set(sessions.filter { $0.isProcessing == true }.map(\.id))
        processingSessionIds = runningIds
        let count = runningIds.count
        if count > 0 {
            logger.info("Seeded \(count) processing session IDs from server", category: .session)
        }
    }

    /// Finalize a session that has stopped processing.
    /// Snapshots live buffer, persists activity lines, syncs events, and extracts dashboard info.
    /// Idempotent: safe to call from both the CompletePlugin event path and the polling path.
    func finalizeSessionCompletion(sessionId: String) async {
        let snapshot = dashboardStreamManager.snapshotLines(for: sessionId)
        if !snapshot.isEmpty {
            updateSessionActivityLines(sessionId: sessionId, lines: snapshot)
        }
        dashboardStreamManager.clearBuffer(for: sessionId)
        // Server sends fresh activity lines via session.updated event
        // (arrives shortly after agent.complete). No need to sync events
        // or extract client-side.
    }

    /// Update dashboard display fields for a session.
    func updateSessionDashboardInfo(
        sessionId: String,
        lastUserPrompt: String? = nil,
        lastAssistantResponse: String? = nil
    ) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { session in
                if let prompt = lastUserPrompt {
                    session.lastUserPrompt = prompt
                }
                if let response = lastAssistantResponse {
                    session.lastAssistantResponse = response
                }
            }
        }
    }

    /// Update persisted activity lines for a session's card display.
    func updateSessionActivityLines(sessionId: String, lines: [ActivityLine]) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { $0.lastActivityLines = lines }
        }
    }

}
