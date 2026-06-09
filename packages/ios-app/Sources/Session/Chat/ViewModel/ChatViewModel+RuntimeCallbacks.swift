import Foundation

extension ChatViewModel {
    /// Set up StreamingManager callbacks for text delta batching
    private func setupStreamingManagerCallbacks() {
        streamingManager.onTextUpdate = { [weak self] messageId, text in
            guard let self = self else { return }
            if let index = self.messageIndex.index(for: messageId) {
                self.messages[index].content = .streaming(text)
                self.messages[index].streamingVersion += 1
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
                    self.messages[index].content = .text(finalText)
                    self.messages[index].isStreaming = false
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
                    // This callback is for capability ordering confirmation
                    logger.verbose("UIUpdateQueue: Turn boundary processed (turn=\(data.turnNumber), isStart=\(data.isStart))", category: .events)

                case .capabilityInvocationStarted(let data):
                    // Capability start was already added to messages in handleCapabilityInvocationStarted
                    // Here we trigger the staggered animation appearance
                    animationCoordinator.queueCapabilityInvocationStart(invocationId: data.invocationId)
                    logger.verbose("UIUpdateQueue: Capability start queued for animation: \(data.modelPrimitiveName)", category: .events)

                case .capabilityInvocationCompleted(let data):
                    // Capability end arrives here in guaranteed order (earlier capabilities first)
                    // Find and update the capability message
                    processOrderedCapabilityInvocationCompleted(data)
                    animationCoordinator.markCapabilityInvocationComplete(invocationId: data.invocationId)
                    logger.verbose("UIUpdateQueue: Capability end processed in order: \(data.invocationId)", category: .events)

                case .messageAppend, .textDelta:
                    // These are handled separately via direct streaming path
                    break
                }
            }
        }
    }

    /// Process a capability end update that has been ordered by UIUpdateQueue
    private func processOrderedCapabilityInvocationCompleted(_ data: UIUpdateQueue.CapabilityInvocationEndData) {
        // Find the capability message by invocationId (O(1) via index, then a bounded scan)
        if let index = messageIndex.index(forCapabilityInvocationId: data.invocationId)
            ?? MessageFinder.lastIndexOfCapabilityInvocation(id: data.invocationId, in: messages) {
            if case .capabilityInvocation(var invocation) = messages[index].content {
                invocation.status = data.success ? .success : .error
                invocation.result = data.result
                invocation.durationMs = data.durationMs
                invocation.completedAt = data.timestamp
                invocation.details = data.details
                invocation.progressMessage = nil
                invocation.progressPercent = nil
                invocation.identity = data.identity
                messages[index].content = .capabilityInvocation(invocation)
                messageIndex.didUpdate(messages[index], at: index)

                // Decrement running capability counter (clamp to 0 for catch-up scenarios)
                runningCapabilityInvocationCount = max(0, runningCapabilityInvocationCount - 1)
            }
        }
    }

    func setupEventProcessingCallbacks() {
        // Set up manager callbacks for batched/ordered processing
        setupUIUpdateQueueCallback()
        setupStreamingManagerCallbacks()
    }


}
