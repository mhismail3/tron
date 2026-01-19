import Foundation
import UIKit
import SwiftUI

// MARK: - Event Handlers

extension ChatViewModel {

    func handleTextDelta(_ delta: String) {
        // Skip text if AskUserQuestion was called in this turn
        // (AskUserQuestion should be the final visible entry when called)
        guard !askUserQuestionCalledInTurn else {
            logger.verbose("Skipping text delta - AskUserQuestion was called in this turn", category: .events)
            return
        }

        // Delegate to StreamingManager for batched processing
        let accepted = streamingManager.handleTextDelta(delta)

        if !accepted {
            logger.warning("Streaming text limit reached, dropping delta", category: .events)
            return
        }

        // Keep legacy state in sync for compatibility
        // (used by handleComplete dashboard update, turn metadata, etc.)
        if streamingMessageId == nil {
            streamingMessageId = streamingManager.streamingMessageId

            // Track as first text message of this turn if not already set
            if let id = streamingMessageId, firstTextMessageIdForTurn == nil {
                firstTextMessageIdForTurn = id
                logger.debug("Tracked first text message for turn: \(id)", category: .events)
            }
        }
        streamingText = streamingManager.streamingText

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

        // Check if this is an AskUserQuestion tool call
        if event.toolName.lowercased() == "askuserquestion" {
            handleAskUserQuestionToolStart(event)
            return
        }

        // Check if this is an OpenBrowser tool call
        if event.toolName.lowercased() == "openbrowser" {
            handleOpenBrowserToolStart(event)
            // Don't return - still display as regular tool use
        }

        let tool = ToolUseData(
            toolName: event.toolName,
            toolCallId: event.toolCallId,
            arguments: event.formattedArguments,
            status: .running
        )

        let message = ChatMessage(role: .assistant, content: .toolUse(tool))
        messages.append(message)
        currentToolMessages[message.id] = message

        // CRITICAL: Make tool immediately visible so it renders without waiting for UIUpdateQueue batch
        animationCoordinator.makeToolVisible(event.toolCallId)

        // Sync to MessageWindowManager for virtual scrolling
        messageWindowManager.appendMessage(message)

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

        // Enqueue tool start for ordered processing and staggered animation
        let toolStartData = UIUpdateQueue.ToolStartData(
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            arguments: event.formattedArguments,
            timestamp: Date()
        )
        uiUpdateQueue.enqueueToolStart(toolStartData)
    }

    /// Handle AskUserQuestion tool start - creates special message (sheet opens on tool.end)
    private func handleAskUserQuestionToolStart(_ event: ToolStartEvent) {
        logger.info("AskUserQuestion tool detected, parsing params", category: .events)

        // Mark that AskUserQuestion was called in this turn
        // This suppresses any subsequent text deltas (question should be final entry)
        askUserQuestionCalledInTurn = true

        // Parse the params from JSON arguments
        guard let paramsData = event.formattedArguments.data(using: .utf8),
              let params = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData) else {
            logger.error("Failed to parse AskUserQuestion params: \(event.formattedArguments.prefix(500))", category: .events)
            // Fall back to regular tool display
            let tool = ToolUseData(
                toolName: event.toolName,
                toolCallId: event.toolCallId,
                arguments: event.formattedArguments,
                status: .running
            )
            let message = ChatMessage(role: .assistant, content: .toolUse(tool))
            messages.append(message)
            // Make tool visible for rendering
            animationCoordinator.makeToolVisible(event.toolCallId)
            return
        }

        // Create AskUserQuestion tool data with pending status
        // In async mode, the tool returns immediately and user answers as a new prompt
        let toolData = AskUserQuestionToolData(
            toolCallId: event.toolCallId,
            params: params,
            answers: [:],
            status: .pending,  // Pending = waiting for user response
            result: nil
        )

        // Create message with AskUserQuestion content
        let message = ChatMessage(role: .assistant, content: .askUserQuestion(toolData))
        messages.append(message)

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            arguments: event.formattedArguments
        )
        currentTurnToolCalls.append(record)

        // Note: Sheet auto-opens on tool.end, not tool.start (async mode)
    }

    /// Handle OpenBrowser tool start - opens Safari in-app browser
    private func handleOpenBrowserToolStart(_ event: ToolStartEvent) {
        logger.info("OpenBrowser tool detected, parsing URL", category: .events)

        // Extract URL directly from arguments dictionary
        guard let args = event.arguments,
              let urlValue = args["url"],
              let urlString = urlValue.value as? String,
              let url = URL(string: urlString) else {
            logger.error("Failed to parse OpenBrowser URL from arguments", category: .events)
            return
        }

        logger.info("Opening Safari with URL: \(urlString)", category: .events)
        safariURL = url
    }

    func handleToolEnd(_ event: ToolEndEvent) {
        logger.info("Tool ended: \(event.toolCallId) success=\(event.success) duration=\(event.durationMs ?? 0)ms", category: .events)
        logger.debug("Tool result: \(event.displayResult.prefix(300))", category: .events)

        // Check if this is an AskUserQuestion tool end
        if let index = messages.lastIndex(where: {
            if case .askUserQuestion(let data) = $0.content {
                return data.toolCallId == event.toolCallId
            }
            return false
        }) {
            if case .askUserQuestion(let data) = messages[index].content {
                // In async mode, tool.end means questions are ready for user
                // Status is already .pending, now auto-open the sheet
                logger.info("AskUserQuestion tool.end - opening sheet for user input", category: .events)
                openAskUserQuestionSheet(for: data)
            }
            return
        }

        // Check if this is a browser tool result with screenshot data
        // (Extract screenshot before queueing - this updates browserFrame, not the message)
        if let index = messages.lastIndex(where: {
            if case .toolUse(let tool) = $0.content {
                return tool.toolCallId == event.toolCallId
            }
            return false
        }) {
            if case .toolUse(let tool) = messages[index].content {
                if tool.toolName.lowercased().contains("browser") {
                    extractAndDisplayBrowserScreenshot(from: event)
                }
            }
        }

        // Update tracked tool call with result
        if let idx = currentTurnToolCalls.firstIndex(where: { $0.toolCallId == event.toolCallId }) {
            currentTurnToolCalls[idx].result = event.displayResult
            currentTurnToolCalls[idx].isError = !event.success
        }

        // Enqueue tool end for ordered processing
        // UIUpdateQueue ensures tool ends are processed in the order tools started
        let toolEndData = UIUpdateQueue.ToolEndData(
            toolCallId: event.toolCallId,
            success: event.success,
            result: event.displayResult,
            durationMs: event.durationMs
        )
        uiUpdateQueue.enqueueToolEnd(toolEndData)
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

        // Reset AskUserQuestion tracking for the new turn
        askUserQuestionCalledInTurn = false

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

        // Notify UIUpdateQueue of turn boundary (resets tool ordering)
        uiUpdateQueue.enqueueTurnBoundary(UIUpdateQueue.TurnBoundaryData(
            turnNumber: event.turnNumber,
            isStart: true
        ))

        // Reset AnimationCoordinator tool state for new turn
        animationCoordinator.resetToolState()

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

        // Remove catching-up notification at natural breakpoint (turn end)
        if let catchUpId = catchingUpMessageId {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                messages.removeAll { $0.id == catchUpId }
            }
            catchingUpMessageId = nil
            logger.info("Catch-up complete - removed notification", category: .events)
        }

        // Update context window if server provides it (ensures iOS stays in sync after model switch)
        if let contextLimit = event.contextLimit {
            currentContextWindow = contextLimit
            logger.debug("Updated context window from turn_end: \(contextLimit)", category: .events)
        }

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
            // - cacheReadTokens/cacheCreationTokens: accumulated cache tokens
            // - cost: accumulated cost from all turns
            if let manager = eventStoreManager {
                do {
                    try manager.updateSessionTokens(
                        sessionId: sessionId,
                        inputTokens: accumulatedInputTokens,
                        outputTokens: accumulatedOutputTokens,
                        lastTurnInputTokens: lastTurnInputTokens,
                        cacheReadTokens: accumulatedCacheReadTokens,
                        cacheCreationTokens: accumulatedCacheCreationTokens,
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

        // Flush any pending UI updates to ensure all tool results are displayed
        uiUpdateQueue.flush()

        flushPendingTextUpdates()

        isProcessing = false

        // Remove catching-up notification if still present
        if let catchUpId = catchingUpMessageId {
            messages.removeAll { $0.id == catchUpId }
            catchingUpMessageId = nil
        }

        finalizeStreamingMessage()
        thinkingText = ""

        // Reset browser dismiss flag for next turn
        userDismissedBrowserThisTurn = false

        // Update dashboard with final response and tool count
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: streamingText.isEmpty ? nil : String(streamingText.prefix(200)),
            lastToolCount: currentTurnToolCalls.isEmpty ? nil : currentTurnToolCalls.count
        )

        currentToolMessages.removeAll()
        currentTurnToolCalls.removeAll()

        // Reset all manager states
        uiUpdateQueue.reset()
        animationCoordinator.resetToolState()
        streamingManager.reset()

        // Close browser session when agent completes
        closeBrowserSession()

        // Refresh context from server to ensure accuracy after all operations
        // This covers: skill.added, rules.loaded, and any other context changes
        Task {
            await refreshContextFromServer()
        }
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
            reason: event.reason,
            summary: event.summary
        )
        messages.append(compactionMessage)

        // Refresh context from server to ensure context limit is also current
        Task {
            await refreshContextFromServer()
        }
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

        // Refresh context from server to ensure context limit is also current
        Task {
            await refreshContextFromServer()
        }
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

        // Refresh context from server - skill removal changes context size
        // Server is authoritative source for accurate token counts after context changes
        Task {
            await refreshContextFromServer()
        }
    }

    func handlePlanModeEntered(_ event: PlanModeEnteredEvent) {
        logger.info("Plan mode entered: skill=\(event.skillName), blocked=\(event.blockedTools.joined(separator: ", "))", category: .events)

        // Update state and add notification to chat
        enterPlanMode(skillName: event.skillName, blockedTools: event.blockedTools)
    }

    func handlePlanModeExited(_ event: PlanModeExitedEvent) {
        logger.info("Plan mode exited: reason=\(event.reason), planPath=\(event.planPath ?? "none")", category: .events)

        // Update state and add notification to chat
        exitPlanMode(reason: event.reason, planPath: event.planPath)
    }

    /// Handle errors from the agent streaming (shows error in chat)
    func handleAgentError(_ message: String) {
        logger.error("Agent error: \(message)", category: .events)

        // Flush and reset all manager states on error
        uiUpdateQueue.flush()
        uiUpdateQueue.reset()
        animationCoordinator.resetToolState()
        streamingManager.reset()

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

    // MARK: - UI Canvas Event Handlers

    func handleUIRenderStart(_ event: UIRenderStartEvent) {
        logger.info("UI render started: canvasId=\(event.canvasId), title=\(event.title ?? "none")", category: .events)

        // Start rendering in canvas state (this will show the sheet)
        uiCanvasState.startRender(
            canvasId: event.canvasId,
            title: event.title,
            toolCallId: event.toolCallId
        )
    }

    func handleUIRenderChunk(_ event: UIRenderChunkEvent) {
        logger.verbose("UI render chunk: canvasId=\(event.canvasId), +\(event.chunk.count) chars", category: .events)

        // Update the canvas with the new chunk
        uiCanvasState.updateRender(
            canvasId: event.canvasId,
            chunk: event.chunk,
            accumulated: event.accumulated
        )
    }

    func handleUIRenderComplete(_ event: UIRenderCompleteEvent) {
        logger.info("UI render complete: canvasId=\(event.canvasId)", category: .events)

        // Convert [String: AnyCodable] to [String: Any] for parsing
        guard let uiDict = event.ui else {
            logger.error("No UI dictionary for canvas \(event.canvasId)", category: .events)
            return
        }

        let rawDict: [String: Any] = uiDict.mapValues { $0.value }

        // Parse the raw UI dictionary into UICanvasComponent
        guard let component = UICanvasParser.parse(rawDict) else {
            logger.error("Failed to parse UI component for canvas \(event.canvasId)", category: .events)
            return
        }

        // Complete the render with the final UI tree
        uiCanvasState.completeRender(
            canvasId: event.canvasId,
            ui: component,
            state: event.state
        )
    }
}
