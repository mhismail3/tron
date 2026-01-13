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

    /// Set background state to pause polling and save battery
    /// Call this from scene phase changes in TronMobileApp
    func setBackgroundState(_ inBackground: Bool) {
        guard isInBackground != inBackground else { return }

        setIsInBackground(inBackground)

        if inBackground {
            logger.info("App entering background - pausing dashboard polling", category: .session)
        } else {
            logger.info("App returning to foreground - resuming dashboard polling", category: .session)
        }
    }

    // MARK: - Dashboard Polling

    /// Start polling for session processing states (call when dashboard is visible)
    func startDashboardPolling() {
        guard !isPollingActive else { return }
        setIsPollingActive(true)
        logger.info("Starting dashboard polling for session states")

        pollingTask = Task { [weak self] in
            // Pre-warm WebSocket connection immediately for faster session entry
            // This runs once at dashboard load, before any polling
            await self?.preWarmConnection()

            while !Task.isCancelled {
                // Skip polling when in background
                if self?.isInBackground == true {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }

                await self?.pollAllSessionStates()

                // Adaptive polling interval: 2s when processing, 10s when idle
                let hasProcessing = self?.processingSessionIds.isEmpty == false
                let interval = hasProcessing ? 2 : 10
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Pre-warm the WebSocket connection so session entry is instant
    /// Called once when dashboard becomes visible
    private func preWarmConnection() async {
        guard !rpcClient.isConnected else {
            logger.verbose("Connection already established, skipping pre-warm", category: .rpc)
            return
        }

        logger.info("Pre-warming WebSocket connection for faster session entry", category: .rpc)
        await rpcClient.connect()

        if rpcClient.isConnected {
            logger.info("WebSocket pre-warm complete - connection ready", category: .rpc)
        } else {
            logger.warning("WebSocket pre-warm failed - will retry on session entry", category: .rpc)
        }
    }

    /// Stop polling (call when leaving dashboard)
    func stopDashboardPolling() {
        guard isPollingActive else { return }
        setIsPollingActive(false)
        pollingTask?.cancel()
        pollingTask = nil
        logger.info("Stopped dashboard polling")
    }

    /// Poll all sessions to check their processing state
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

    /// Check a single session's processing state from the server
    func checkSessionProcessingState(sessionId: String) async {
        do {
            if !rpcClient.isConnected {
                await rpcClient.connect()
                if !rpcClient.isConnected {
                    return
                }
            }

            let state = try await rpcClient.getAgentStateForSession(sessionId: sessionId)

            let wasProcessing = processingSessionIds.contains(sessionId) || (sessions.first(where: { $0.id == sessionId })?.isProcessing == true)
            let isNowProcessing = state.isRunning

            if wasProcessing != isNowProcessing {
                logger.info("Session \(sessionId) processing state changed: \(wasProcessing) -> \(isNowProcessing)")
                setSessionProcessing(sessionId, isProcessing: isNowProcessing)

                if wasProcessing && !isNowProcessing {
                    try? await syncSessionEvents(sessionId: sessionId)
                    extractDashboardInfoFromEvents(sessionId: sessionId)
                }
            }
        } catch {
            logger.debug("Failed to check session \(sessionId) state: \(error.localizedDescription)")
        }
    }

    /// Update dashboard display fields for a session
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

    /// Extract dashboard info from events after sync
    func extractDashboardInfoFromEvents(sessionId: String) {
        do {
            let events = try eventDB.getEventsBySession(sessionId)

            // Find the last user message
            if let lastUserEvent = events.last(where: { $0.type == "message.user" }) {
                let userPrompt = extractTextFromContent(lastUserEvent.payload["content"]?.value)
                if !userPrompt.isEmpty {
                    updateSessionDashboardInfo(sessionId: sessionId, lastUserPrompt: userPrompt)
                }
            }

            // Find the last assistant message and count tools
            if let lastAssistantEvent = events.last(where: { $0.type == "message.assistant" }) {
                var responseText = ""
                var toolCount = 0

                if let content = lastAssistantEvent.payload["content"]?.value {
                    if let text = content as? String {
                        responseText = text
                    } else if let blocks = content as? [[String: Any]] {
                        for block in blocks {
                            if let type = block["type"] as? String {
                                if type == "tool_use" {
                                    toolCount += 1
                                } else if type == "text", let text = block["text"] as? String {
                                    if responseText.isEmpty {
                                        responseText = text
                                    }
                                }
                            }
                        }
                    } else if let blocks = content as? [Any] {
                        for element in blocks {
                            if let block = element as? [String: Any],
                               let type = block["type"] as? String {
                                if type == "tool_use" {
                                    toolCount += 1
                                } else if type == "text", let text = block["text"] as? String {
                                    if responseText.isEmpty {
                                        responseText = text
                                    }
                                }
                            }
                        }
                    }
                }

                updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: responseText,
                    lastToolCount: toolCount > 0 ? toolCount : nil
                )
            }
        } catch {
            logger.error("Failed to extract dashboard info for session \(sessionId): \(error.localizedDescription)")
        }
    }

    /// Helper to extract text from content
    func extractTextFromContent(_ content: Any?) -> String {
        guard let content = content else { return "" }

        if let text = content as? String {
            return text
        }

        if let blocks = content as? [[String: Any]] {
            var texts: [String] = []
            for block in blocks {
                if let type = block["type"] as? String, type == "text",
                   let text = block["text"] as? String {
                    texts.append(text)
                }
            }
            return texts.joined()
        }

        if let blocks = content as? [Any] {
            var texts: [String] = []
            for element in blocks {
                if let block = element as? [String: Any],
                   let type = block["type"] as? String, type == "text",
                   let text = block["text"] as? String {
                    texts.append(text)
                }
            }
            return texts.joined()
        }

        return ""
    }
}
