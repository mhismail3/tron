import Foundation
import UIKit

// MARK: - Event Handlers

extension ChatViewModel {

    func handleTextDelta(_ delta: String) {
        // If there's no active streaming message, create a new one
        if streamingMessageId == nil {
            let newStreamingMessage = ChatMessage.streaming()
            messages.append(newStreamingMessage)
            streamingMessageId = newStreamingMessage.id
            streamingText = ""
            logger.verbose("Created new streaming message after tool calls id=\(newStreamingMessage.id)", category: .events)

            // Track as first text message of this turn if not already set
            if firstTextMessageIdForTurn == nil {
                firstTextMessageIdForTurn = newStreamingMessage.id
                logger.debug("Tracked first text message for turn: \(newStreamingMessage.id)", category: .events)
            }
        }

        // Batch text deltas for better performance
        pendingTextDelta += delta
        streamingText += delta

        // Cancel any pending update task
        textUpdateTask?.cancel()

        // Schedule batched update (coalesce rapid updates)
        textUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.textUpdateInterval ?? 50_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.updateStreamingMessage(with: .streaming(self.streamingText))
                self.pendingTextDelta = ""
            }
        }

        logger.verbose("Text delta received: +\(delta.count) chars, total: \(streamingText.count)", category: .events)
    }

    func handleThinkingDelta(_ delta: String) {
        thinkingText += delta
        logger.verbose("Thinking delta: +\(delta.count) chars", category: .events)
    }

    func handleToolStart(_ event: ToolStartEvent) {
        logger.info("Tool started: \(event.toolName) [\(event.toolCallId)]", category: .events)
        logger.debug("Tool args: \(event.formattedArguments.prefix(200))", category: .events)

        // Finalize any current streaming text before tool starts
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        let tool = ToolUseData(
            toolName: event.toolName,
            toolCallId: event.toolCallId,
            arguments: event.formattedArguments,
            status: .running
        )

        let message = ChatMessage(role: .assistant, content: .toolUse(tool))
        messages.append(message)
        currentToolMessages[message.id] = message

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            arguments: event.formattedArguments
        )
        currentTurnToolCalls.append(record)

        // Track that a browser tool is active (for showing browser window)
        if event.toolName.lowercased().contains("browser") {
            logger.info("Browser tool detected", category: .events)
            // Mark that we have an active browser session
            if browserStatus == nil {
                browserStatus = BrowserGetStatusResult(hasBrowser: true, isStreaming: false, currentUrl: nil)
            }
        }
    }

    func handleToolEnd(_ event: ToolEndEvent) {
        logger.info("Tool ended: \(event.toolCallId) success=\(event.success) duration=\(event.durationMs ?? 0)ms", category: .events)
        logger.debug("Tool result: \(event.displayResult.prefix(300))", category: .events)

        // Find and update the tool message
        if let index = messages.lastIndex(where: {
            if case .toolUse(let tool) = $0.content {
                return tool.toolCallId == event.toolCallId
            }
            return false
        }) {
            if case .toolUse(var tool) = messages[index].content {
                tool.status = event.success ? .success : .error
                tool.result = event.displayResult
                tool.durationMs = event.durationMs
                messages[index].content = .toolUse(tool)

                // Check if this is a browser tool result with screenshot data
                if tool.toolName.lowercased().contains("browser") {
                    extractAndDisplayBrowserScreenshot(from: event)
                }
            }
        } else {
            logger.warning("Could not find tool message for toolCallId=\(event.toolCallId)", category: .events)
        }

        // Update tracked tool call with result
        if let idx = currentTurnToolCalls.firstIndex(where: { $0.toolCallId == event.toolCallId }) {
            currentTurnToolCalls[idx].result = event.displayResult
            currentTurnToolCalls[idx].isError = !event.success
        }
    }

    /// Extract screenshot from browser tool result and display it
    /// Prefers the full screenshot from event.details, falls back to parsing text output
    private func extractAndDisplayBrowserScreenshot(from event: ToolEndEvent) {
        // First, try to get the full screenshot from details (preferred - untruncated)
        if let details = event.details,
           let screenshotBase64 = details.screenshot,
           let imageData = Data(base64Encoded: screenshotBase64),
           let image = UIImage(data: imageData) {
            logger.info("Browser screenshot from details (\(image.size.width)x\(image.size.height))", category: .events)
            browserFrame = image
            // Only auto-show if user hasn't manually dismissed this turn
            if !userDismissedBrowserThisTurn && !showBrowserWindow {
                showBrowserWindow = true
            }
            return
        }

        // Fallback: try to extract from text result (may be truncated)
        let result = event.displayResult

        // Look for base64 image data in the result
        // Format: "Screenshot captured (base64): iVBORw0KGgo..." or just raw base64
        let patterns = [
            "Screenshot captured \\(base64\\): ([A-Za-z0-9+/=]+)",
            "base64\\): ([A-Za-z0-9+/=]+)",
            "data:image/[^;]+;base64,([A-Za-z0-9+/=]+)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: result, options: [], range: NSRange(result.startIndex..., in: result)),
               let range = Range(match.range(at: 1), in: result) {
                let base64String = String(result[range])

                // Decode base64 to image
                if let imageData = Data(base64Encoded: base64String),
                   let image = UIImage(data: imageData) {
                    logger.info("Browser screenshot from text (\(image.size.width)x\(image.size.height))", category: .events)
                    browserFrame = image
                    // Only auto-show if user hasn't manually dismissed this turn
                    if !userDismissedBrowserThisTurn && !showBrowserWindow {
                        showBrowserWindow = true
                    }
                    return
                }
            }
        }

        // Also check if the result itself looks like base64 image data (PNG/JPEG magic bytes when decoded)
        if result.hasPrefix("iVBOR") || result.hasPrefix("/9j/") {
            if let imageData = Data(base64Encoded: result),
               let image = UIImage(data: imageData) {
                logger.info("Browser screenshot from raw base64 (\(image.size.width)x\(image.size.height))", category: .events)
                browserFrame = image
                // Only auto-show if user hasn't manually dismissed this turn
                if !userDismissedBrowserThisTurn && !showBrowserWindow {
                    showBrowserWindow = true
                }
            }
        }
    }

    func handleTurnStart(_ event: TurnStartEvent) {
        logger.info("Turn \(event.turnNumber) started", category: .events)

        // Finalize any streaming text from the previous turn
        if streamingMessageId != nil && !streamingText.isEmpty {
            flushPendingTextUpdates()
            finalizeStreamingMessage()
            streamingText = ""
        }

        // Clear tool tracking for the new turn
        if !currentTurnToolCalls.isEmpty {
            logger.debug("Starting Turn \(event.turnNumber), clearing \(currentTurnToolCalls.count) completed tool records from previous turn", category: .events)
            currentTurnToolCalls.removeAll()
        }
        if !currentToolMessages.isEmpty {
            logger.debug("Clearing \(currentToolMessages.count) tool message references from previous turn", category: .events)
            currentToolMessages.removeAll()
        }

        // Track turn boundary for multi-turn metadata assignment
        turnStartMessageIndex = messages.count
        firstTextMessageIdForTurn = nil
        logger.debug("Turn \(event.turnNumber) boundary set at message index \(turnStartMessageIndex ?? -1)", category: .events)
    }

    func handleTurnEnd(_ event: TurnEndEvent) {
        logger.info("Turn ended, tokens: in=\(event.tokenUsage?.inputTokens ?? 0) out=\(event.tokenUsage?.outputTokens ?? 0)", category: .events)

        // Find the message to update with metadata
        // Priority: streaming message > first text message of turn > fallback search
        var targetIndex: Int?

        if let id = streamingMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            targetIndex = index
            logger.debug("Using streaming message for turn metadata at index \(index)", category: .events)
        } else if let firstTextId = firstTextMessageIdForTurn,
                  let index = messages.firstIndex(where: { $0.id == firstTextId }) {
            // Streaming message was finalized (e.g., before tool call) but we tracked the first text
            targetIndex = index
            logger.debug("Using tracked first text message for turn metadata at index \(index)", category: .events)
        } else if let startIndex = turnStartMessageIndex {
            // Fallback: find first assistant text message from turn start
            for i in startIndex..<messages.count {
                if messages[i].role == .assistant,
                   case .text = messages[i].content {
                    targetIndex = i
                    logger.debug("Found first assistant text message at index \(i) for turn metadata", category: .events)
                    break
                }
            }
        }

        // Update the target message with metadata
        if let index = targetIndex {
            messages[index].tokenUsage = event.tokenUsage
            messages[index].model = currentModel
            messages[index].latencyMs = event.data?.duration
            messages[index].stopReason = event.stopReason
            messages[index].turnNumber = event.turnNumber

            // Compute incremental tokens (delta from previous turn) for display
            // Use tracked previous turn value instead of searching messages (which may not have tokenUsage)
            if let usage = event.tokenUsage {
                let incrementalInput = max(0, usage.inputTokens - previousTurnFinalInputTokens)
                messages[index].incrementalTokens = TokenUsage(
                    inputTokens: incrementalInput,
                    outputTokens: usage.outputTokens,
                    cacheReadTokens: usage.cacheReadTokens,
                    cacheCreationTokens: usage.cacheCreationTokens
                )
                logger.debug("Incremental tokens: in=\(incrementalInput) (prev=\(previousTurnFinalInputTokens))", category: .events)
            }
        } else {
            logger.warning("Could not find message to update with turn metadata (turn=\(event.turnNumber))", category: .events)
        }

        // Update all assistant messages from this turn with turn number
        if let startIndex = turnStartMessageIndex {
            for i in startIndex..<messages.count where messages[i].role == .assistant {
                messages[i].turnNumber = event.turnNumber
            }
        }

        // Clear turn tracking
        turnStartMessageIndex = nil
        firstTextMessageIdForTurn = nil

        // Update token tracking
        if let usage = event.tokenUsage {
            // Store last turn's input tokens for context bar calculation
            // This represents the actual current context size sent to the LLM
            lastTurnInputTokens = usage.inputTokens

            // Track this turn's input for next turn's incremental calculation
            previousTurnFinalInputTokens = usage.inputTokens

            // Accumulate ALL tokens for billing tracking
            // Input tokens: each API call charges for full context window
            accumulatedInputTokens += usage.inputTokens
            accumulatedOutputTokens += usage.outputTokens
            accumulatedCacheReadTokens += usage.cacheReadTokens ?? 0
            accumulatedCacheCreationTokens += usage.cacheCreationTokens ?? 0
            accumulatedCost += event.cost ?? 0

            // Total usage shows current context input + accumulated output
            // The context bar uses lastTurnInputTokens via contextPercentage
            totalTokenUsage = TokenUsage(
                inputTokens: lastTurnInputTokens,  // Current context size for display
                outputTokens: accumulatedOutputTokens,
                cacheReadTokens: accumulatedCacheReadTokens > 0 ? accumulatedCacheReadTokens : nil,
                cacheCreationTokens: accumulatedCacheCreationTokens > 0 ? accumulatedCacheCreationTokens : nil
            )
            logger.debug("Total tokens: context=\(lastTurnInputTokens) out=\(accumulatedOutputTokens) accumulatedIn=\(accumulatedInputTokens)", category: .events)

            // Update CachedSession with token info for dashboard
            // - inputTokens: accumulated for billing
            // - outputTokens: accumulated
            // - lastTurnInputTokens: current context size for context bar
            // - cost: accumulated cost from all turns
            if let manager = eventStoreManager {
                do {
                    try manager.updateSessionTokens(
                        sessionId: sessionId,
                        inputTokens: accumulatedInputTokens,
                        outputTokens: accumulatedOutputTokens,
                        lastTurnInputTokens: lastTurnInputTokens,
                        cost: accumulatedCost
                    )
                } catch {
                    logger.error("Failed to update session tokens: \(error.localizedDescription)", category: .events)
                }
            }
        }
    }

    func handleAgentTurn(_ event: AgentTurnEvent) {
        logger.info("Agent turn received: \(event.messages.count) messages, \(event.toolUses.count) tool uses, \(event.toolResults.count) tool results", category: .events)

        guard let manager = eventStoreManager else {
            logger.warning("No EventStoreManager to cache agent turn content", category: .events)
            return
        }

        // Convert AgentTurnEvent messages to cacheable format
        var turnMessages: [[String: Any]] = []
        for msg in event.messages {
            var messageDict: [String: Any] = ["role": msg.role]

            switch msg.content {
            case .text(let text):
                messageDict["content"] = text
            case .blocks(let blocks):
                var contentBlocks: [[String: Any]] = []
                for block in blocks {
                    switch block {
                    case .text(let text):
                        contentBlocks.append(["type": "text", "text": text])
                    case .toolUse(let id, let name, let input):
                        var inputDict: [String: Any] = [:]
                        for (key, value) in input {
                            inputDict[key] = value.value
                        }
                        contentBlocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": inputDict
                        ])
                    case .toolResult(let toolUseId, let content, let isError):
                        contentBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": toolUseId,
                            "content": content,
                            "is_error": isError
                        ])
                    case .thinking(let text):
                        contentBlocks.append(["type": "thinking", "thinking": text])
                    case .unknown:
                        break
                    }
                }
                messageDict["content"] = contentBlocks
            }
            turnMessages.append(messageDict)
        }

        // Cache the turn content for merging with server events
        manager.cacheTurnContent(
            sessionId: sessionId,
            turnNumber: event.turnNumber,
            messages: turnMessages
        )

        // Trigger sync AFTER caching content
        logger.info("Triggering sync after caching agent turn content", category: .events)
        Task {
            await syncSessionEventsFromServer()
        }
    }

    func handleComplete() {
        logger.info("Agent complete, finalizing message (streamingText: \(streamingText.count) chars, toolCalls: \(currentTurnToolCalls.count))", category: .events)
        flushPendingTextUpdates()

        isProcessing = false
        finalizeStreamingMessage()
        thinkingText = ""

        // Update dashboard with final response and tool count
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: streamingText.isEmpty ? nil : String(streamingText.prefix(200)),
            lastToolCount: currentTurnToolCalls.isEmpty ? nil : currentTurnToolCalls.count
        )

        currentToolMessages.removeAll()
        currentTurnToolCalls.removeAll()

        // Close browser session when agent completes
        closeBrowserSession()
    }

    func handleCompaction(_ event: CompactionEvent) {
        let tokensSaved = event.tokensBefore - event.tokensAfter
        logger.info("Context compacted: \(event.tokensBefore) -> \(event.tokensAfter) tokens (saved \(tokensSaved), reason: \(event.reason))", category: .events)

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Update context tracking - the new context size is tokensAfter
        lastTurnInputTokens = event.tokensAfter
        previousTurnFinalInputTokens = event.tokensAfter
        logger.debug("Updated lastTurnInputTokens to \(event.tokensAfter) after compaction", category: .events)

        // Add compaction notification pill to chat
        let compactionMessage = ChatMessage.compaction(
            tokensBefore: event.tokensBefore,
            tokensAfter: event.tokensAfter,
            reason: event.reason
        )
        messages.append(compactionMessage)
    }

    func handleContextCleared(_ event: ContextClearedEvent) {
        let tokensFreed = event.tokensBefore - event.tokensAfter
        logger.info("Context cleared: \(event.tokensBefore) -> \(event.tokensAfter) tokens (freed \(tokensFreed))", category: .events)

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Update context tracking - the new context size is tokensAfter
        lastTurnInputTokens = event.tokensAfter
        previousTurnFinalInputTokens = event.tokensAfter
        logger.debug("Updated lastTurnInputTokens to \(event.tokensAfter) after context clear", category: .events)

        // Add context cleared notification pill to chat
        let clearedMessage = ChatMessage.contextCleared(
            tokensBefore: event.tokensBefore,
            tokensAfter: event.tokensAfter
        )
        messages.append(clearedMessage)
    }

    func handleMessageDeleted(_ event: MessageDeletedEvent) {
        logger.info("Message deleted: targetType=\(event.targetType), eventId=\(event.targetEventId)", category: .events)

        // Add message deleted notification pill to chat
        let deletedMessage = ChatMessage.messageDeleted(targetType: event.targetType)
        messages.append(deletedMessage)
    }

    func handleSkillRemoved(_ event: SkillRemovedEvent) {
        logger.info("Skill removed: \(event.skillName)", category: .events)

        // Add skill removed notification pill to chat
        let skillRemovedMessage = ChatMessage.skillRemoved(skillName: event.skillName)
        messages.append(skillRemovedMessage)
    }

    func handleError(_ message: String) {
        logger.error("Agent error: \(message)", category: .events)
        isProcessing = false
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(message.prefix(100)))"
        )
        finalizeStreamingMessage()
        messages.append(.error(message))
        thinkingText = ""

        // Close browser session on error
        closeBrowserSession()
    }

    /// Sync session events from server after turn completes
    func syncSessionEventsFromServer() async {
        guard let manager = eventStoreManager else {
            logger.warning("No EventStoreManager available for sync", category: .events)
            return
        }

        do {
            try await manager.syncSessionEvents(sessionId: sessionId)
            logger.info("Synced session events from server for session \(sessionId)", category: .events)
        } catch {
            logger.error("Failed to sync session events: \(error.localizedDescription)", category: .events)
        }
    }
}
