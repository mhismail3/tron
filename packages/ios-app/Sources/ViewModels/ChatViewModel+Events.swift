import Foundation
import UIKit
import SwiftUI

// MARK: - Event Handlers

extension ChatViewModel {

    func handleTextDelta(_ delta: String) {
        // Skip text if AskUserQuestion was called in this turn
        // (AskUserQuestion should be the final visible entry when called)
        guard !askUserQuestionState.calledInTurn else {
            logger.verbose("Skipping text delta - AskUserQuestion was called in this turn", category: .events)
            return
        }

        // Delegate to StreamingManager for batched processing
        let accepted = streamingManager.handleTextDelta(delta)

        if !accepted {
            logger.warning("Streaming text limit reached, dropping delta", category: .events)
            return
        }

        // Track as first text message of this turn if not already set
        // (StreamingManager is now single source of truth for streamingMessageId)
        if let id = streamingManager.streamingMessageId, firstTextMessageIdForTurn == nil {
            firstTextMessageIdForTurn = id
            logger.debug("Tracked first text message for turn: \(id)", category: .events)
        }

        logger.verbose("Text delta received: +\(delta.count) chars, total: \(streamingManager.streamingText.count)", category: .events)
    }

    func handleThinkingDelta(_ delta: String) {
        // Process through handler (accumulates thinking text)
        let result = eventHandler.handleThinkingDelta(delta)

        // Create thinking message on first delta (so it appears BEFORE the text response)
        if thinkingMessageId == nil {
            let thinkingMessage = ChatMessage.thinking(result.thinkingText, isStreaming: true)
            messages.append(thinkingMessage)
            thinkingMessageId = thinkingMessage.id
            messageWindowManager.appendMessage(thinkingMessage)
            logger.debug("Created thinking message: \(thinkingMessage.id)", category: .events)
        } else if let id = thinkingMessageId,
                  let index = MessageFinder.indexById(id, in: messages) {
            // Update existing thinking message with accumulated content
            messages[index].content = .thinking(visible: result.thinkingText, isExpanded: false, isStreaming: true)
        }

        // Also route to ThinkingState for sheet/history functionality
        thinkingState.handleThinkingDelta(delta)

        logger.verbose("Thinking delta: +\(delta.count) chars, total: \(result.thinkingText.count)", category: .events)
    }

    func handleToolStart(_ event: ToolStartEvent) {
        // Process through handler (classifies tool type, parses params)
        let result = eventHandler.handleToolStart(event, context: self)
        logger.debug("Tool args: \(event.formattedArguments.prefix(200))", category: .events)

        // Finalize any current streaming text before tool starts
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Check if this is an AskUserQuestion tool call
        if result.isAskUserQuestion {
            handleAskUserQuestionToolStart(event, params: result.askUserQuestionParams)
            return
        }

        // Check if this is an OpenBrowser tool call
        if result.isOpenBrowser {
            handleOpenBrowserToolStart(url: result.openBrowserURL)
            // Don't return - still display as regular tool use
        }

        var message = ChatMessage(role: .assistant, content: .toolUse(result.tool))

        // For RenderAppUI: use tracker for atomic state management
        if event.toolName.lowercased() == "renderappui" {
            if let argsData = event.formattedArguments.data(using: .utf8),
               let argsJson = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
               let canvasId = argsJson["canvasId"] as? String {

                // Check if chip already exists from ui_render_chunk (via tracker)
                if let chipState = renderAppUIChipTracker.getChip(canvasId: canvasId),
                   let index = MessageFinder.indexById(chipState.messageId, in: messages),
                   case .renderAppUI(var chipData) = messages[index].content {
                    // Chip already exists - update toolCallId to real one
                    let oldToolCallId = chipData.toolCallId
                    chipData.toolCallId = event.toolCallId
                    messages[index].content = .renderAppUI(chipData)

                    // Update tracker atomically
                    renderAppUIChipTracker.updateToolCallId(canvasId: canvasId, realToolCallId: event.toolCallId)

                    // Update currentToolMessages with correct ID
                    currentToolMessages[messages[index].id] = messages[index]

                    // Track tool call for persistence
                    let record = ToolCallRecord(
                        toolCallId: event.toolCallId,
                        toolName: event.toolName,
                        arguments: event.formattedArguments
                    )
                    currentTurnToolCalls.append(record)

                    logger.info("Updated existing RenderAppUI chip toolCallId: \(canvasId), \(oldToolCallId) → \(event.toolCallId)", category: .events)
                    return // Don't create a new message
                }

                // No existing chip - create one now
                let title = argsJson["title"] as? String
                let chipData = RenderAppUIChipData(
                    toolCallId: event.toolCallId,
                    canvasId: canvasId,
                    title: title,
                    status: .rendering,
                    errorMessage: nil
                )
                message.content = .renderAppUI(chipData)

                // Track in tracker (single source of truth)
                renderAppUIChipTracker.createChipFromToolStart(
                    canvasId: canvasId,
                    messageId: message.id,
                    toolCallId: event.toolCallId,
                    title: title
                )
                logger.debug("Created RenderAppUI chip from tool_start: \(canvasId)", category: .events)
            }
        } else if let pendingRender = renderAppUIChipTracker.consumePendingRenderStart(toolCallId: event.toolCallId) {
            // Handle pending UI render start (legacy path) - via tracker
            let chipData = RenderAppUIChipData(
                toolCallId: event.toolCallId,
                canvasId: pendingRender.canvasId,
                title: pendingRender.title,
                status: .rendering,
                errorMessage: nil
            )
            message.content = .renderAppUI(chipData)

            // Track in tracker (single source of truth)
            renderAppUIChipTracker.createChipFromToolStart(
                canvasId: pendingRender.canvasId,
                messageId: message.id,
                toolCallId: event.toolCallId,
                title: pendingRender.title
            )
            logger.debug("Applied pending UI render start to new tool message: \(pendingRender.canvasId)", category: .events)
        }

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
        if result.isBrowserTool {
            logger.info("Browser tool detected", category: .events)
            // Mark that we have an active browser session
            if browserState.browserStatus == nil {
                browserState.browserStatus = BrowserGetStatusResult(hasBrowser: true, isStreaming: false, currentUrl: nil)
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
    /// - Parameters:
    ///   - event: The tool start event
    ///   - params: Pre-parsed AskUserQuestion params (from eventHandler)
    private func handleAskUserQuestionToolStart(_ event: ToolStartEvent, params: AskUserQuestionParams?) {
        logger.info("AskUserQuestion tool detected", category: .events)

        // Mark that AskUserQuestion was called in this turn
        // This suppresses any subsequent text deltas (question should be final entry)
        askUserQuestionState.calledInTurn = true

        // Use pre-parsed params, fall back to regular tool display if parsing failed
        guard let params = params else {
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
    /// - Parameter url: Pre-parsed URL (from eventHandler)
    private func handleOpenBrowserToolStart(url: URL?) {
        logger.info("OpenBrowser tool detected", category: .events)

        guard let url = url else {
            logger.error("Failed to parse OpenBrowser URL from arguments", category: .events)
            return
        }

        logger.info("Opening Safari with URL: \(url.absoluteString)", category: .events)
        browserState.safariURL = url
    }

    func handleToolEnd(_ event: ToolEndEvent) {
        // Process through handler (extracts status and result)
        let result = eventHandler.handleToolEnd(event)
        logger.info("Tool ended: \(result.toolCallId) status=\(result.status) duration=\(result.durationMs ?? 0)ms", category: .events)
        logger.debug("Tool result: \(result.result.prefix(300))", category: .events)

        // Check if this is an AskUserQuestion tool end
        if let index = MessageFinder.lastIndexOfAskUserQuestion(toolCallId: result.toolCallId, in: messages) {
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
        if let index = MessageFinder.lastIndexOfToolUse(toolCallId: result.toolCallId, in: messages) {
            if case .toolUse(let tool) = messages[index].content {
                if tool.toolName.lowercased().contains("browser") {
                    // Pass original event for screenshot extraction (needs event.details)
                    extractAndDisplayBrowserScreenshot(from: event)
                }
            }
        }

        // Update tracked tool call with result
        if let idx = currentTurnToolCalls.firstIndex(where: { $0.toolCallId == result.toolCallId }) {
            currentTurnToolCalls[idx].result = result.result
            currentTurnToolCalls[idx].isError = (result.status == .error)
        }

        // Enqueue tool end for ordered processing
        // UIUpdateQueue ensures tool ends are processed in the order tools started
        let toolEndData = UIUpdateQueue.ToolEndData(
            toolCallId: result.toolCallId,
            success: (result.status == .success),
            result: result.result,
            durationMs: result.durationMs
        )
        uiUpdateQueue.enqueueToolEnd(toolEndData)
    }

    /// Extract screenshot from browser tool result and display it.
    /// Uses BrowserScreenshotService for extraction, handling event details and text patterns.
    private func extractAndDisplayBrowserScreenshot(from event: ToolEndEvent) {
        guard let result = BrowserScreenshotService.extractScreenshot(from: event) else {
            return
        }

        logger.info("Browser screenshot from \(result.source.rawValue) (\(result.image.size.width)x\(result.image.size.height))", category: .events)
        browserState.browserFrame = result.image

        // Only auto-show if user hasn't manually dismissed this turn
        if !browserState.userDismissedBrowserThisTurn && !browserState.showBrowserWindow {
            browserState.showBrowserWindow = true
        }
    }

    func handleTurnStart(_ event: TurnStartEvent) {
        // Process through handler (resets handler streaming state)
        let result = eventHandler.handleTurnStart(event)
        logger.info("Turn \(result.turnNumber) started", category: .events)

        // Reset AskUserQuestion tracking for the new turn
        askUserQuestionState.calledInTurn = false

        // Finalize any streaming text from the previous turn
        if streamingManager.streamingMessageId != nil && !streamingManager.streamingText.isEmpty {
            flushPendingTextUpdates()
            finalizeStreamingMessage()
        }

        // Clear thinking state for the new turn
        thinkingMessageId = nil

        // Notify ThinkingState of new turn (clears previous turn's thinking for sheet)
        thinkingState.startTurn(result.turnNumber, model: currentModel)

        // Clear tool tracking for the new turn
        if !currentTurnToolCalls.isEmpty {
            logger.debug("Starting Turn \(result.turnNumber), clearing \(currentTurnToolCalls.count) completed tool records from previous turn", category: .events)
            currentTurnToolCalls.removeAll()
        }
        if !currentToolMessages.isEmpty {
            logger.debug("Clearing \(currentToolMessages.count) tool message references from previous turn", category: .events)
            currentToolMessages.removeAll()
        }

        // Notify UIUpdateQueue of turn boundary (resets tool ordering)
        uiUpdateQueue.enqueueTurnBoundary(UIUpdateQueue.TurnBoundaryData(
            turnNumber: result.turnNumber,
            isStart: true
        ))

        // Reset AnimationCoordinator tool state for new turn
        animationCoordinator.resetToolState()

        // Track turn boundary for multi-turn metadata assignment
        turnStartMessageIndex = messages.count
        firstTextMessageIdForTurn = nil
        logger.debug("Turn \(result.turnNumber) boundary set at message index \(turnStartMessageIndex ?? -1)", category: .events)
    }

    func handleTurnEnd(_ event: TurnEndEvent) {
        // Process through handler (extracts normalized values)
        let result = eventHandler.handleTurnEnd(event)

        // Log both raw and normalized usage for debugging
        let rawIn = result.tokenUsage?.inputTokens ?? 0
        let rawOut = result.tokenUsage?.outputTokens ?? 0
        let hasNormalized = result.normalizedUsage != nil
        logger.info("Turn \(result.turnNumber) ended, tokens: raw_in=\(rawIn) raw_out=\(rawOut) hasNormalizedUsage=\(hasNormalized)", category: .events)

        // Log normalized values if available (server's pre-calculated values)
        if let normalized = result.normalizedUsage {
            logger.debug("NormalizedUsage: newInput=\(normalized.newInputTokens) contextWindow=\(normalized.contextWindowTokens) cacheRead=\(normalized.cacheReadTokens)", category: .events)
        } else {
            logger.debug("NormalizedUsage not available, will use fallback local calculation", category: .events)
        }

        // Persist thinking content for this turn (before clearing state)
        Task {
            await thinkingState.endTurn()
        }

        // Update thinking message to mark streaming as complete
        // This removes the spinning brain icon and "Thinking" header
        if let id = thinkingMessageId,
           let index = MessageFinder.indexById(id, in: messages),
           case .thinking(let visible, let isExpanded, _) = messages[index].content {
            messages[index].content = .thinking(visible: visible, isExpanded: isExpanded, isStreaming: false)
            logger.debug("Marked thinking message as no longer streaming", category: .events)
        }

        // Find the message to update with metadata
        // Priority: streaming message > first text message of turn > fallback search
        var targetIndex: Int?

        if let id = streamingManager.streamingMessageId,
           let index = MessageFinder.indexById(id, in: messages) {
            targetIndex = index
            logger.debug("Using streaming message for turn metadata at index \(index)", category: .events)
        } else if let firstTextId = firstTextMessageIdForTurn,
                  let index = MessageFinder.indexById(firstTextId, in: messages) {
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
            messages[index].tokenUsage = result.tokenUsage
            messages[index].model = currentModel
            messages[index].latencyMs = result.durationMs
            messages[index].stopReason = result.stopReason
            messages[index].turnNumber = result.turnNumber

            // Use server-provided normalizedUsage for incremental tokens (preferred)
            // Falls back to local calculation only if server doesn't provide normalizedUsage
            //
            // Note: normalizedUsage is always available on stream.turn_end. For message.assistant,
            // it's available for no-tool turns. For tool turns, the pre-tool message.assistant
            // is created before turn_end, so normalizedUsage isn't available there. However,
            // the live streaming case here uses stream.turn_end, so normalizedUsage should
            // Server MUST provide normalizedUsage - no fallback
            if let normalized = result.normalizedUsage {
                messages[index].incrementalTokens = TokenUsage(
                    inputTokens: normalized.newInputTokens,
                    outputTokens: normalized.outputTokens,
                    cacheReadTokens: normalized.cacheReadTokens,
                    cacheCreationTokens: normalized.cacheCreationTokens
                )
                logger.debug("[TOKEN-FLOW] iOS: stream.turn_end received", category: .events)
                logger.debug("  turn=\(result.turnNumber), newInput=\(normalized.newInputTokens), contextWindow=\(normalized.contextWindowTokens), output=\(normalized.outputTokens)", category: .events)
            } else {
                logger.error("[TOKEN-FLOW] iOS: stream.turn_end MISSING normalizedUsage (turn=\(result.turnNumber))", category: .events)
            }
        } else {
            logger.warning("Could not find message to update with turn metadata (turn=\(result.turnNumber))", category: .events)
        }

        // Update all assistant messages from this turn with turn number
        if let startIndex = turnStartMessageIndex {
            for i in startIndex..<messages.count where messages[i].role == .assistant {
                messages[i].turnNumber = result.turnNumber
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
        if let contextLimit = result.contextLimit {
            contextState.currentContextWindow = contextLimit
            logger.debug("Updated context window from turn_end: \(contextLimit)", category: .events)
        }

        // Server MUST provide normalizedUsage for context tracking
        if let normalized = result.normalizedUsage {
            contextState.updateFromNormalizedUsage(normalized)
            logger.debug("[TOKEN-FLOW] iOS: Context state updated from stream.turn_end", category: .events)
            logger.debug("  lastTurnInput=\(contextState.lastTurnInputTokens)", category: .events)
        } else {
            logger.error("[TOKEN-FLOW] iOS: Context tracking stale - no normalizedUsage on turn_end", category: .events)
        }

        // Update token tracking and accumulation
        if let usage = result.tokenUsage {
            let contextSize = result.normalizedUsage?.contextWindowTokens ?? 0
            logger.info("LIVE handleTurnEnd: contextSize=\(contextSize)", category: .events)

            // Accumulate ALL tokens for billing tracking
            contextState.accumulate(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens ?? 0,
                cacheCreationTokens: usage.cacheCreationTokens ?? 0,
                cost: result.cost ?? 0
            )

            // Total usage shows current context + accumulated output
            contextState.totalTokenUsage = TokenUsage(
                inputTokens: contextSize,  // Current context size for display
                outputTokens: contextState.accumulatedOutputTokens,
                cacheReadTokens: contextState.accumulatedCacheReadTokens > 0 ? contextState.accumulatedCacheReadTokens : nil,
                cacheCreationTokens: contextState.accumulatedCacheCreationTokens > 0 ? contextState.accumulatedCacheCreationTokens : nil
            )
            logger.debug("Total tokens: context=\(contextSize) out=\(contextState.accumulatedOutputTokens) accumulatedIn=\(contextState.accumulatedInputTokens)", category: .events)

            // Update CachedSession with token info for dashboard
            if let manager = eventStoreManager {
                do {
                    try manager.updateSessionTokens(
                        sessionId: sessionId,
                        inputTokens: contextState.accumulatedInputTokens,
                        outputTokens: contextState.accumulatedOutputTokens,
                        lastTurnInputTokens: contextSize,
                        cacheReadTokens: contextState.accumulatedCacheReadTokens,
                        cacheCreationTokens: contextState.accumulatedCacheCreationTokens,
                        cost: contextState.accumulatedCost
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
        // Capture streaming text before finalization clears it
        let finalStreamingText = streamingManager.streamingText
        logger.info("Agent complete, finalizing message (streamingText: \(finalStreamingText.count) chars, toolCalls: \(currentTurnToolCalls.count))", category: .events)

        // Process through handler (resets handler state)
        _ = eventHandler.handleComplete()

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

        // NOTE: Do NOT clear ThinkingState here - thinking caption should persist
        // until the user sends a new message (cleared by startTurn on next turn)

        // Reset browser dismiss flag for next turn
        browserState.userDismissedBrowserThisTurn = false

        // Update dashboard with final response and tool count
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: finalStreamingText.isEmpty ? nil : String(finalStreamingText.prefix(200)),
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
        // Process event through handler
        let result = eventHandler.handleCompaction(event)
        logger.info("Context compacted: \(result.tokensBefore) -> \(result.tokensAfter) tokens (saved \(result.tokensSaved), reason: \(result.reason))", category: .events)

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Update context tracking - the new context size is tokensAfter
        contextState.lastTurnInputTokens = result.tokensAfter
        logger.debug("Updated lastTurnInputTokens to \(result.tokensAfter) after compaction", category: .events)

        // Add compaction notification pill to chat
        let compactionMessage = ChatMessage.compaction(
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter,
            reason: result.reason,
            summary: result.summary
        )
        messages.append(compactionMessage)

        // Refresh context from server to ensure context limit is also current
        Task {
            await refreshContextFromServer()
        }
    }

    func handleContextCleared(_ event: ContextClearedEvent) {
        // Process event through handler
        let result = eventHandler.handleContextCleared(event)
        logger.info("Context cleared: \(result.tokensBefore) -> \(result.tokensAfter) tokens (freed \(result.tokensFreed))", category: .events)

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Update context tracking - the new context size is tokensAfter
        contextState.lastTurnInputTokens = result.tokensAfter
        logger.debug("Updated lastTurnInputTokens to \(result.tokensAfter) after context clear", category: .events)

        // Add context cleared notification pill to chat
        let clearedMessage = ChatMessage.contextCleared(
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter
        )
        messages.append(clearedMessage)

        // Refresh context from server to ensure context limit is also current
        Task {
            await refreshContextFromServer()
        }
    }

    func handleMessageDeleted(_ event: MessageDeletedEvent) {
        // Process event through handler
        let result = eventHandler.handleMessageDeleted(event)
        logger.info("Message deleted: targetType=\(result.targetType), eventId=\(result.targetEventId)", category: .events)

        // Add message deleted notification pill to chat
        let deletedMessage = ChatMessage.messageDeleted(targetType: result.targetType)
        messages.append(deletedMessage)
    }

    func handleSkillRemoved(_ event: SkillRemovedEvent) {
        // Process event through handler
        let result = eventHandler.handleSkillRemoved(event)
        logger.info("Skill removed: \(result.skillName)", category: .events)

        // Add skill removed notification pill to chat
        let skillRemovedMessage = ChatMessage.skillRemoved(skillName: result.skillName)
        messages.append(skillRemovedMessage)

        // Refresh context from server - skill removal changes context size
        // Server is authoritative source for accurate token counts after context changes
        Task {
            await refreshContextFromServer()
        }
    }

    func handlePlanModeEntered(_ event: PlanModeEnteredEvent) {
        // Process event through handler
        let result = eventHandler.handlePlanModeEntered(event)
        logger.info("Plan mode entered: skill=\(result.skillName), blocked=\(result.blockedTools.joined(separator: ", "))", category: .events)

        // Update state and add notification to chat
        enterPlanMode(skillName: result.skillName, blockedTools: result.blockedTools)
    }

    func handlePlanModeExited(_ event: PlanModeExitedEvent) {
        // Process event through handler
        let result = eventHandler.handlePlanModeExited(event)
        logger.info("Plan mode exited: reason=\(result.reason), planPath=\(result.planPath ?? "none")", category: .events)

        // Update state and add notification to chat
        exitPlanMode(reason: result.reason, planPath: result.planPath)
    }

    /// Handle errors from the agent streaming (shows error in chat)
    func handleAgentError(_ message: String) {
        // Process through handler (resets handler state)
        let result = eventHandler.handleAgentError(message)
        logger.error("Agent error: \(result.message)", category: .events)

        // Flush and reset all manager states on error
        uiUpdateQueue.flush()
        uiUpdateQueue.reset()
        animationCoordinator.resetToolState()
        streamingManager.reset()

        isProcessing = false
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(result.message.prefix(100)))"
        )
        finalizeStreamingMessage()
        messages.append(.error(result.message))

        // NOTE: Do NOT clear ThinkingState here - thinking caption should persist
        // so user can see what was happening before the error (cleared on next turn)

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

        // Find the RenderAppUI message by toolCallId
        // Check if already converted to chip (from handleToolStart) or still a toolUse
        if let index = MessageFinder.lastIndexOfRenderAppUI(toolCallId: event.toolCallId, in: messages) {
            // Update or convert to chip with rendering status
            let chipData = RenderAppUIChipData(
                toolCallId: event.toolCallId,
                canvasId: event.canvasId,
                title: event.title,
                status: .rendering,
                errorMessage: nil
            )
            messages[index].content = .renderAppUI(chipData)

            // Track in new tracker (creates or updates)
            if renderAppUIChipTracker.hasChip(canvasId: event.canvasId) {
                renderAppUIChipTracker.updateToolCallId(canvasId: event.canvasId, realToolCallId: event.toolCallId)
            } else {
                renderAppUIChipTracker.createChipFromToolStart(
                    canvasId: event.canvasId,
                    messageId: messages[index].id,
                    toolCallId: event.toolCallId,
                    title: event.title
                )
            }
            logger.debug("Updated/converted RenderAppUI to chip: \(event.canvasId)", category: .events)
        } else {
            // Tool message doesn't exist yet (ui.render.start arrived before tool.start via streaming)
            // Store the event in tracker for processing when tool.start arrives
            renderAppUIChipTracker.storePendingRenderStart(event)
            logger.debug("Stored pending UI render start for toolCallId: \(event.toolCallId)", category: .events)
        }

        // Start rendering in canvas state (this will show the sheet)
        uiCanvasState.startRender(
            canvasId: event.canvasId,
            title: event.title,
            toolCallId: event.toolCallId
        )
    }

    func handleUIRenderChunk(_ event: UIRenderChunkEvent) {
        logger.verbose("UI render chunk: canvasId=\(event.canvasId), +\(event.chunk.count) chars", category: .events)

        // CRITICAL FIX: ui_render_chunk arrives BEFORE tool_start in streaming mode.
        // Create the chip on FIRST chunk so user sees "Rendering..." immediately.
        // Use tracker to check if chip exists (single source of truth)
        if !renderAppUIChipTracker.hasChip(canvasId: event.canvasId) {
            // First chunk for this canvasId - create the rendering chip
            // Try to extract title from accumulated JSON
            let title = extractTitleFromAccumulated(event.accumulated)

            let message = ChatMessage(role: .assistant, content: .renderAppUI(RenderAppUIChipData(
                toolCallId: "pending_\(event.canvasId)", // Placeholder
                canvasId: event.canvasId,
                title: title,
                status: .rendering,
                errorMessage: nil
            )))
            messages.append(message)

            // Track in tracker (single source of truth, returns placeholder toolCallId)
            let placeholderToolCallId = renderAppUIChipTracker.createChipFromChunk(
                canvasId: event.canvasId,
                messageId: message.id,
                title: title
            )

            // Make chip immediately visible
            animationCoordinator.makeToolVisible(placeholderToolCallId)

            // Sync to MessageWindowManager
            messageWindowManager.appendMessage(message)

            logger.info("Created RenderAppUI chip from first chunk: \(event.canvasId), title=\(title ?? "nil")", category: .events)

            // Also start canvas render state (shows sheet)
            uiCanvasState.startRender(
                canvasId: event.canvasId,
                title: title,
                toolCallId: placeholderToolCallId
            )
        }

        // FIX: Ensure canvas exists even if chip was created by tool_start
        // This handles the race condition where tool_start arrives before ui_render_chunk.
        // tool_start creates the chip but doesn't call startRender(), so the canvas
        // won't exist when updateRender() is called. This check ensures we create
        // the canvas state before attempting to update it.
        if !uiCanvasState.hasCanvas(event.canvasId) {
            let title = extractTitleFromAccumulated(event.accumulated)
            let toolCallId = getToolCallIdForCanvas(event.canvasId) ?? "pending_\(event.canvasId)"
            uiCanvasState.startRender(
                canvasId: event.canvasId,
                title: title,
                toolCallId: toolCallId
            )
            logger.info("Created canvas state for existing chip: \(event.canvasId)", category: .events)
        }

        // Update the canvas with the new chunk
        uiCanvasState.updateRender(
            canvasId: event.canvasId,
            chunk: event.chunk,
            accumulated: event.accumulated
        )
    }

    /// Extract title from accumulated RenderAppUI JSON arguments
    private func extractTitleFromAccumulated(_ accumulated: String) -> String? {
        // Try to extract "title" field: {"canvasId": "...", "title": "...", ...}
        // Use NSRegularExpression for compatibility
        let pattern = #""title"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: accumulated, options: [], range: NSRange(accumulated.startIndex..., in: accumulated)),
              let range = Range(match.range(at: 1), in: accumulated) else {
            return nil
        }
        return String(accumulated[range])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Get the toolCallId for an existing RenderAppUI chip
    private func getToolCallIdForCanvas(_ canvasId: String) -> String? {
        // Use tracker as single source of truth
        guard let chipState = renderAppUIChipTracker.getChip(canvasId: canvasId),
              let message = messages.first(where: { $0.id == chipState.messageId }),
              case .renderAppUI(let data) = message.content else {
            return nil
        }
        return data.toolCallId
    }

    func handleUIRenderComplete(_ event: UIRenderCompleteEvent) {
        logger.info("UI render complete: canvasId=\(event.canvasId)", category: .events)

        // Update chip status to complete (use tracker as single source of truth)
        if let chipState = renderAppUIChipTracker.getChip(canvasId: event.canvasId),
           let index = MessageFinder.indexById(chipState.messageId, in: messages),
           case .renderAppUI(var chipData) = messages[index].content {
            chipData.status = .complete
            chipData.errorMessage = nil
            messages[index].content = .renderAppUI(chipData)
            logger.debug("Updated RenderAppUI chip to complete: \(event.canvasId)", category: .events)
        }

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

    func handleUIRenderError(_ event: UIRenderErrorEvent) {
        logger.warning("UI render error: canvasId=\(event.canvasId), error=\(event.error)", category: .events)

        // Update chip status to error (use tracker as single source of truth)
        if let chipState = renderAppUIChipTracker.getChip(canvasId: event.canvasId),
           let index = MessageFinder.indexById(chipState.messageId, in: messages),
           case .renderAppUI(var chipData) = messages[index].content {
            chipData.status = .error
            chipData.errorMessage = event.error
            messages[index].content = .renderAppUI(chipData)
            logger.debug("Updated RenderAppUI chip to error: \(event.canvasId)", category: .events)
        }

        // Mark the canvas as errored - this will update the UI to show the error
        // instead of leaving it stuck in "Rendering..." state
        uiCanvasState.errorRender(canvasId: event.canvasId, error: event.error)
    }

    func handleUIRenderRetry(_ event: UIRenderRetryEvent) {
        logger.info("UI render retry: canvasId=\(event.canvasId), attempt=\(event.attempt)", category: .events)

        // Validation failure means error - chip shows error state (not tappable)
        // The agent will create a NEW chip with the retry, so this one stays as error
        // Use tracker as single source of truth
        if let chipState = renderAppUIChipTracker.getChip(canvasId: event.canvasId),
           let index = MessageFinder.indexById(chipState.messageId, in: messages),
           case .renderAppUI(var chipData) = messages[index].content {
            chipData.status = .error
            chipData.errorMessage = "Error generating"
            messages[index].content = .renderAppUI(chipData)
            logger.debug("Updated RenderAppUI chip to error (validation failed): \(event.canvasId)", category: .events)
        }

        // Update canvas to show retry status - keeps the sheet open so user sees progress
        // The agent will automatically retry with a corrected UI definition
        uiCanvasState.setRetrying(
            canvasId: event.canvasId,
            attempt: event.attempt,
            errors: event.errors
        )
    }

    // MARK: - Todo Event Handlers

    func handleTodosUpdated(_ event: TodosUpdatedEvent) {
        // Process through handler (extracts todos)
        let result = eventHandler.handleTodosUpdated(event)
        logger.debug("Todos updated: count=\(result.todos.count), restoredCount=\(result.restoredCount)", category: .events)

        // Update todo state from server event
        todoState.handleTodosUpdated(event)
    }
}
