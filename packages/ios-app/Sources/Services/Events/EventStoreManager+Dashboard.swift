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

    /// Restore processing session IDs from persistence
    func restoreProcessingSessionIds() {
        if let ids = UserDefaults.standard.array(forKey: "tron.processingSessionIds") as? [String] {
            processingSessionIds = Set(ids)
            // Update session flags
            for sessionId in processingSessionIds {
                if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                    updateSession(at: index) { $0.isProcessing = true }
                }
            }
            let count = processingSessionIds.count
            logger.info("Restored \(count) processing session IDs")
        }
    }

    // MARK: - Background State

    /// Set background state to pause polling and save battery.
    /// Delegates to DashboardPoller.
    func setBackgroundState(_ inBackground: Bool) {
        dashboardPoller.setBackgroundState(inBackground)
    }

    // MARK: - Dashboard Polling

    /// Start polling for session processing states.
    /// Delegates to DashboardPoller.
    func startDashboardPolling() {
        dashboardPoller.start()
    }

    /// Stop polling.
    /// Delegates to DashboardPoller.
    func stopDashboardPolling() {
        dashboardPoller.stop()
    }

    /// Poll all sessions to check their processing state.
    func pollAllSessionStates() async {
        let sessionsToCheck = sessions.filter { session in
            session.isProcessing == true || processingSessionIds.contains(session.id)
        }

        let shouldCheckAll = Int.random(in: 0..<10) == 0
        let checkList = shouldCheckAll ? sessions : (sessionsToCheck.isEmpty ? Array(sessions.prefix(3)) : sessionsToCheck)

        for session in checkList {
            await checkSessionProcessingState(sessionId: session.id)
        }
    }

    /// Check a single session's processing state from the server.
    func checkSessionProcessingState(sessionId: String) async {
        let wasProcessing = processingSessionIds.contains(sessionId) ||
            (sessions.first(where: { $0.id == sessionId })?.isProcessing == true)

        guard let isNowProcessing = await sessionStateChecker.checkProcessingState(sessionId: sessionId) else {
            return
        }

        if wasProcessing != isNowProcessing {
            logger.info("Session \(sessionId) processing state changed: \(wasProcessing) -> \(isNowProcessing)")
            setSessionProcessing(sessionId, isProcessing: isNowProcessing)

            if wasProcessing && !isNowProcessing {
                try? await syncSessionEvents(sessionId: sessionId)
                extractDashboardInfoFromEvents(sessionId: sessionId)
            }
        }
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

    /// Extract dashboard info from events after sync.
    /// Delegates to ContentExtractor utility.
    func extractDashboardInfoFromEvents(sessionId: String) {
        do {
            let events = try eventDB.getEventsBySession(sessionId)
            let info = ContentExtractor.extractDashboardInfo(from: events)

            updateSessionDashboardInfo(
                sessionId: sessionId,
                lastUserPrompt: info.lastUserPrompt,
                lastAssistantResponse: info.lastAssistantResponse,
                lastToolCount: info.lastToolCount
            )
        } catch {
            logger.error("Failed to extract dashboard info for session \(sessionId): \(error.localizedDescription)")
        }
    }
}

// MARK: - DashboardPollerDelegate Conformance

extension EventStoreManager: DashboardPollerDelegate {

    func pollerShouldPreWarm() async {
        await sessionStateChecker.preWarmConnection()
    }

    func pollerShouldPollSessions() async {
        await pollAllSessionStates()
    }

    func pollerHasProcessingSessions() -> Bool {
        !processingSessionIds.isEmpty
    }
}
