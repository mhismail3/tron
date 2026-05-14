import Foundation

// MARK: - Subagent Event Handlers

extension ChatViewModel {

    func handleSubagentSpawnedResult(_ result: SubagentSpawnedPlugin.Result) {
        logger.info("Subagent spawned: \(result.subagentSessionId) for task: \(result.task.prefix(50))...", category: .chat)

        let resolvedSpawnType: SubagentSpawnType
        if let decoded = SubagentSpawnType(from: result.spawnType) {
            resolvedSpawnType = decoded
        } else {
            // Wire contract: `spawnType` is always emitted by the server.
            // Missing / unknown value signals a schema drift — log loudly and
            // use the safe default (capabilityAgent) so the chip still renders.
            logger.error(
                "Subagent live event missing/unknown spawnType=\(result.spawnType ?? "<nil>") for session \(result.subagentSessionId); defaulting to capabilityAgent",
                category: .chat
            )
            resolvedSpawnType = .capabilityAgent
        }

        subagentState.trackSpawn(
            invocationId: result.invocationId ?? result.subagentSessionId,
            subagentSessionId: result.subagentSessionId,
            task: result.task,
            model: result.model,
            blocking: result.blocking,
            spawnType: resolvedSpawnType
        )

        updateCapabilityMessageToSubagentChip(
            invocationId: result.invocationId ?? result.subagentSessionId,
            subagentSessionId: result.subagentSessionId
        )
    }

    func handleSubagentStatusResult(_ result: SubagentStatusPlugin.Result) {
        logger.debug("Subagent status: \(result.subagentSessionId) - \(result.status) turn \(result.currentTurn)", category: .chat)

        let status: SubagentStatus = .running
        subagentState.updateStatus(
            subagentSessionId: result.subagentSessionId,
            status: status,
            currentTurn: result.currentTurn
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentCompletedResult(_ result: SubagentCompletedPlugin.Result) {
        logger.info("Subagent completed: \(result.subagentSessionId) in \(result.totalTurns) turns, \(result.duration)ms, model=\(result.model ?? "unknown")", category: .chat)

        subagentState.complete(
            subagentSessionId: result.subagentSessionId,
            resultSummary: result.resultSummary,
            fullOutput: result.fullOutput,
            totalTurns: result.totalTurns,
            duration: result.duration,
            tokenUsage: result.tokenUsage,
            model: result.model
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentFailedResult(_ result: SubagentFailedPlugin.Result) {
        logger.error("Subagent failed: \(result.subagentSessionId) - \(result.error)", category: .chat)

        subagentState.fail(
            subagentSessionId: result.subagentSessionId,
            error: result.error,
            duration: result.duration
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentForwardedEventResult(_ result: SubagentEventPlugin.Result) {
        logger.debug("Subagent forwarded event: \(result.subagentSessionId) - \(result.innerEventType)", category: .chat)

        subagentState.addForwardedEvent(
            subagentSessionId: result.subagentSessionId,
            eventType: result.innerEventType,
            eventData: result.innerEventData,
            timestamp: result.innerEventTimestamp
        )
    }

    func handleSubagentResultAvailableResult(_ result: SubagentResultAvailablePlugin.Result) {
        logger.info("Subagent result available: sessionId=\(result.subagentSessionId), success=\(result.success), notify=\(result.notify), task=\(result.task.prefix(50))", category: .chat)

        // Server decides whether iOS should surface a notification. When
        // notify=false, the parent agent is actively running and the backend
        // delivers subagent results via system-prompt injection — no iOS
        // action needed. When notify=true, the parent is idle and the user
        // reviews results manually. Blocking subagents never emit this event,
        // so no client-side blocking check is needed.
        guard result.notify else {
            logger.debug("Server says no notification needed for subagent: \(result.subagentSessionId)", category: .chat)
            return
        }

        subagentState.markResultsPending(subagentSessionId: result.subagentSessionId)
        logger.debug("Marked subagent results as pending: \(result.subagentSessionId)", category: .chat)

        guard let subagent = subagentState.getSubagent(sessionId: result.subagentSessionId) else {
            logger.warning("Subagent data not found for result available event: \(result.subagentSessionId) - notification will not be shown", category: .chat)
            return
        }

        let entry = SubagentResultEntry(
            subagentSessionId: result.subagentSessionId,
            taskPreview: subagent.taskPreview,
            success: result.success
        )

        // Consolidate: update existing notification or create new one
        if let existingIdx = messages.lastIndex(where: { msg in
            if case .systemEvent(.subagentResultsReady) = msg.content { return true }
            return false
        }) {
            if case .systemEvent(.subagentResultsReady(var results)) = messages[existingIdx].content {
                results.append(entry)
                messages[existingIdx].content = .systemEvent(.subagentResultsReady(results: results))
                logger.info("Updated consolidated notification: \(results.count) results", category: .chat)
            }
        } else {
            let notification = ChatMessage(
                role: .system,
                content: .systemEvent(.subagentResultsReady(results: [entry]))
            )
            appendToMessages(notification)
            logger.info("Created subagent result notification: \(result.subagentSessionId)", category: .chat)
        }
    }

    // MARK: - Subagent Helpers

    private func updateCapabilityMessageToSubagentChip(invocationId: String, subagentSessionId: String) {
        guard let data = subagentState.getSubagent(sessionId: subagentSessionId) else {
            logger.warning("No subagent data found for session \(subagentSessionId)", category: .chat)
            return
        }

        if let index = MessageFinder.indexOfSubagentCapabilityInvocation(invocationId: invocationId, in: messages) {
            messages[index].content = .subagent(data)
            logger.debug("Converted capability message to subagent chip for \(subagentSessionId)", category: .chat)
        }
    }

    private func updateSubagentMessageContent(subagentSessionId: String) {
        guard let data = subagentState.getSubagent(sessionId: subagentSessionId) else {
            return
        }

        if let index = MessageFinder.indexBySubagentSessionId(subagentSessionId, in: messages) {
            messages[index].content = .subagent(data)
        }
    }

    // MARK: - Subagent Result Delivery

    /// Deliver all pending subagent results through the engine.
    /// The server retrieves unconsumed results, formats them, and spawns a prompt run (or queues).
    /// Called from both "Send" (individual) and "Send All" buttons in subagent sheets.
    func deliverSubagentResults(idempotencyKey: EngineIdempotencyKey) {
        let pending = subagentState.pendingSubagents
        guard !pending.isEmpty else { return }
        logger.info("Delivering \(pending.count) pending subagent results via server", category: .chat)

        for subagent in pending {
            subagentState.markResultsSent(subagentSessionId: subagent.subagentSessionId)
        }
        subagentState.showDetailSheet = false

        // Remove the "results ready" notification — the chip replaces it.
        removeFromMessages { msg in
            if case .systemEvent(.subagentResultsReady) = msg.content { return true }
            return false
        }

        // Add chip to chat immediately (matches UserInteractionCoordinator pattern).
        // On reconstruction the server-tagged message.user event produces the same chip.
        let chip = ChatMessage(
            role: .user,
            content: .subagentResultsDelivered(subagentCount: pending.count)
        )
        appendToMessages(chip)
        currentTurn += 1

        Task {
            do {
                let response = try await engineClient.agent.deliverSubagentResults(idempotencyKey: idempotencyKey)
                logInfo("Subagent results delivered: count=\(response.subagentCount), queued=\(response.queued)")
            } catch {
                logError("Failed to deliver subagent results: \(error.localizedDescription)")
                showError("Could not deliver subagent results: \(error.localizedDescription)")
            }
        }
    }
}
