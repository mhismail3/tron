import Foundation

extension ChatViewModel {
    /// Set up StreamingManager callbacks for text delta batching
    private func setupStreamingManagerCallbacks() {
        streamingManager.onTextUpdate = { [weak self] messageId, text in
            guard let self = self else { return }
            if let index = self.messageIndex.index(for: messageId) {
                self.updateMessage(at: index) { message in
                    message.content = .streaming(text)
                    message.streamingVersion += 1
                }
            }
        }

        streamingManager.onCreateStreamingMessage = { [weak self] in
            guard let self = self else { return UUID() }
            let message = ChatMessage.streaming()
            self.appendToMessages(message)
            return message.id
        }

        streamingManager.onFinalizeMessage = { [weak self] messageId, finalText in
            guard let self = self else { return }
            if let index = self.messageIndex.index(for: messageId) {
                if finalText.isEmpty {
                    self.removeFromMessages(at: index)
                } else {
                    self.updateMessage(at: index) { message in
                        message.content = .text(finalText)
                        message.isStreaming = false
                    }
                }
            }
        }
    }

    /// Set up UIUpdateQueue callback for processing batched, ordered updates
    private func setupUIUpdateQueueCallback() {
        uiUpdateQueue.onProcessUpdates = { [weak self] updates in
            guard let self = self else { return }

            for update in updates {
                switch update {
                case .turnBoundary(let data):
                    // Turn boundaries are handled directly in handleTurnStart/handleTurnEnd
                    // This callback is for tool ordering confirmation
                    logger.verbose("UIUpdateQueue: Turn boundary processed (turn=\(data.turnNumber), isStart=\(data.isStart))", category: .events)

                case .toolInvocationStarted(let data):
                    // Tool start was already added to messages in handleToolInvocationStarted
                    // Here we trigger the staggered animation appearance
                    animationCoordinator.queueToolInvocationStart(invocationId: data.invocationId)
                    logger.verbose("UIUpdateQueue: Tool start queued for animation: \(data.toolName)", category: .events)

                case .toolInvocationCompleted(let data):
                    // Tool end arrives here in guaranteed order (earlier tools first)
                    // Find and update the tool message
                    processOrderedToolInvocationCompleted(data)
                    animationCoordinator.markToolInvocationComplete(invocationId: data.invocationId)
                    logger.verbose("UIUpdateQueue: Tool end processed in order: \(data.invocationId)", category: .events)

                case .messageAppend, .textDelta:
                    // These are handled separately via direct streaming path
                    break
                }
            }
        }
    }

    /// Process a tool end update that has been ordered by UIUpdateQueue
    private func processOrderedToolInvocationCompleted(_ data: UIUpdateQueue.ToolInvocationEndData) {
        // Find the tool message by invocationId (O(1) via index, then a bounded scan)
        if let index = messageIndex.index(forToolInvocationId: data.invocationId)
            ?? MessageFinder.lastIndexOfToolInvocation(id: data.invocationId, in: messages) {
            if case .toolInvocation(var invocation) = messages[index].content {
                invocation.status = data.success ? .success : .error
                invocation.result = data.result
                invocation.durationMs = data.durationMs
                invocation.completedAt = data.timestamp
                invocation.details = data.details
                invocation.errorClassification = data.failure.map(ToolErrorClassification.init(failure:))
                invocation.progressMessage = nil
                invocation.progressPercent = nil
                invocation.identity = invocation.identity.merging(data.identity)
                updateMessage(at: index) { message in
                    message.content = .toolInvocation(invocation)
                }

                // Decrement running tool counter (clamp to 0 for catch-up scenarios)
                runningToolInvocationCount = max(0, runningToolInvocationCount - 1)
            }
        }
    }

    func setupEventProcessingCallbacks() {
        // Set up manager callbacks for batched/ordered processing
        setupUIUpdateQueueCallback()
        setupStreamingManagerCallbacks()
    }


}
