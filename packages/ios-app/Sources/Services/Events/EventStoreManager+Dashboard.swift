import Foundation

// MARK: - Dashboard & Processing State

extension EventStoreManager {

    /// Mark a session as processing (agent is thinking)
    func setSessionProcessing(_ sessionId: String, isProcessing: Bool) {
        if isProcessing {
            processingSessionIds.insert(sessionId)
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

        do {
            try await syncSessionEvents(sessionId: sessionId)
        } catch {
            logger.error("Failed to sync events after completion for \(sessionId): \(error)", category: .database)
        }
        extractDashboardInfoFromEvents(sessionId: sessionId)
    }

    /// Update dashboard display fields for a session.
    func updateSessionDashboardInfo(
        sessionId: String,
        lastUserPrompt: String? = nil,
        lastAssistantResponse: String? = nil,
        lastToolCount: Int? = nil
    ) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { session in
                if let prompt = lastUserPrompt {
                    session.lastUserPrompt = prompt
                }
                if let response = lastAssistantResponse {
                    session.lastAssistantResponse = response
                }
                if let toolCount = lastToolCount {
                    session.lastToolCount = toolCount
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

    /// Extract dashboard info from events after sync.
    /// Delegates to ContentExtractor utility.
    func extractDashboardInfoFromEvents(sessionId: String) {
        do {
            let events = try eventDB.events.getBySession(sessionId)

            let info = ContentExtractor.extractDashboardInfo(from: events)

            updateSessionDashboardInfo(
                sessionId: sessionId,
                lastUserPrompt: info.lastUserPrompt,
                lastAssistantResponse: info.lastAssistantResponse,
                lastToolCount: info.lastToolCount
            )

            // Build activity lines from stored events for card display.
            // Always rebuild — persisted lines from live snapshots may have stale subagent status.
            let activityLines = ContentExtractor.extractActivityLines(from: events)
            if !activityLines.isEmpty {
                updateSessionActivityLines(sessionId: sessionId, lines: activityLines)
            }
        } catch {
            logger.error("Failed to extract dashboard info for session \(sessionId): \(error.localizedDescription)")
        }
    }
}
