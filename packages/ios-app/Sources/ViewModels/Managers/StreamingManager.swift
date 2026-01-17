import Foundation

// MARK: - Streaming Manager
// Manages text delta batching, thinking content, and backpressure

@MainActor @Observable
final class StreamingManager {

    // MARK: - Configuration

    struct Config {
        /// Batch interval for text updates (100ms)
        static let textBatchIntervalNanos: UInt64 = 100_000_000
        /// Maximum streaming text size to prevent memory exhaustion (10MB)
        static let maxStreamingTextSize = 10_000_000
        /// Thinking text size limit (1MB)
        static let maxThinkingTextSize = 1_000_000
    }

    // MARK: - Streaming State

    /// Current streaming message ID
    private(set) var streamingMessageId: UUID?

    /// Accumulated streaming text
    private(set) var streamingText: String = ""

    /// Pending text delta (not yet flushed to UI)
    private var pendingTextDelta: String = ""

    /// Batch update task
    private var textUpdateTask: Task<Void, Never>?

    /// Accumulated thinking text
    private(set) var thinkingText: String = ""

    /// Whether currently streaming
    var isStreaming: Bool {
        streamingMessageId != nil
    }

    // MARK: - Callbacks

    /// Called when streaming text should be updated in UI
    var onTextUpdate: ((UUID, String) -> Void)?

    /// Called when a new streaming message should be created
    var onCreateStreamingMessage: (() -> UUID)?

    /// Called when streaming message should be finalized
    var onFinalizeMessage: ((UUID, String) -> Void)?

    /// Called when thinking text updates
    var onThinkingUpdate: ((String) -> Void)?

    // MARK: - Text Delta Handling

    /// Handle incoming text delta
    /// Returns false if backpressure limit reached
    @discardableResult
    func handleTextDelta(_ delta: String) -> Bool {
        // Enforce backpressure limit
        guard streamingText.count + delta.count < Config.maxStreamingTextSize else {
            return false
        }

        // Create streaming message if needed
        if streamingMessageId == nil {
            if let createMessage = onCreateStreamingMessage {
                streamingMessageId = createMessage()
            }
        }

        // Accumulate delta
        pendingTextDelta += delta
        streamingText += delta

        // Schedule batched update
        scheduleBatchUpdate()

        return true
    }

    /// Schedule a batched UI update
    private func scheduleBatchUpdate() {
        // Cancel any pending update
        textUpdateTask?.cancel()

        textUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Config.textBatchIntervalNanos)
            guard !Task.isCancelled else { return }

            flushPendingText()
        }
    }

    /// Flush pending text to UI immediately
    func flushPendingText() {
        textUpdateTask?.cancel()
        textUpdateTask = nil

        guard !pendingTextDelta.isEmpty,
              let messageId = streamingMessageId else { return }

        onTextUpdate?(messageId, streamingText)
        pendingTextDelta = ""
    }

    // MARK: - Thinking Text

    /// Handle incoming thinking delta
    @discardableResult
    func handleThinkingDelta(_ delta: String) -> Bool {
        // Enforce limit
        guard thinkingText.count + delta.count < Config.maxThinkingTextSize else {
            return false
        }

        thinkingText += delta
        onThinkingUpdate?(thinkingText)

        return true
    }

    /// Clear thinking text
    func clearThinking() {
        thinkingText = ""
        onThinkingUpdate?("")
    }

    // MARK: - Message Finalization

    /// Finalize the current streaming message
    /// Returns the final text content
    func finalizeStreamingMessage() -> String {
        // Flush any pending updates first
        flushPendingText()

        guard let messageId = streamingMessageId else { return "" }

        let finalText = streamingText

        // Notify finalization
        onFinalizeMessage?(messageId, finalText)

        // Reset state
        streamingMessageId = nil
        streamingText = ""
        pendingTextDelta = ""

        return finalText
    }

    /// Cancel current streaming without finalizing
    func cancelStreaming() {
        textUpdateTask?.cancel()
        textUpdateTask = nil

        streamingMessageId = nil
        streamingText = ""
        pendingTextDelta = ""
    }

    // MARK: - State Queries

    /// Check if backpressure limit is approaching
    var isApproachingLimit: Bool {
        streamingText.count > Config.maxStreamingTextSize * 8 / 10
    }

    /// Current streaming text length
    var currentTextLength: Int {
        streamingText.count
    }

    /// Remaining capacity before backpressure
    var remainingCapacity: Int {
        Config.maxStreamingTextSize - streamingText.count
    }

    // MARK: - In-Progress Session Handling

    /// Handle catching up to an in-progress streaming session
    /// Used when user joins a session that's already streaming
    func catchUpToInProgress(existingText: String, messageId: UUID) {
        streamingMessageId = messageId
        streamingText = existingText
        pendingTextDelta = ""

        // Notify UI of current state
        onTextUpdate?(messageId, streamingText)
    }

    // MARK: - Reset

    /// Reset all streaming state
    func reset() {
        textUpdateTask?.cancel()
        textUpdateTask = nil

        streamingMessageId = nil
        streamingText = ""
        pendingTextDelta = ""
        thinkingText = ""
    }
}
