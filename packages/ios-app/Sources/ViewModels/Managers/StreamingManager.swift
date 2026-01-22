import Foundation
import QuartzCore
import UIKit

// MARK: - Streaming Manager
// Manages text delta batching using CADisplayLink for efficient, battery-friendly updates.
// Replaces Task.sleep-based batching which caused perpetual deferral during rapid deltas.

@MainActor @Observable
final class StreamingManager {

    // MARK: - Configuration

    struct Config {
        /// Maximum streaming text size to prevent memory exhaustion (10MB)
        static let maxStreamingTextSize = 10_000_000
        /// Thinking text size limit (1MB)
        static let maxThinkingTextSize = 1_000_000
        /// Target updates per second (30fps for smooth text appearance)
        static let targetUpdatesPerSecond: Int = 30
    }

    // MARK: - Streaming State

    /// Current streaming message ID
    private(set) var streamingMessageId: UUID?

    /// Accumulated streaming text
    private(set) var streamingText: String = ""

    /// Pending text delta (not yet flushed to UI)
    @ObservationIgnored
    private var pendingTextDelta: String = ""

    /// Accumulated thinking text
    private(set) var thinkingText: String = ""

    /// Whether currently streaming
    var isStreaming: Bool {
        streamingMessageId != nil
    }

    // MARK: - Display Link Timer

    /// Display link wrapper that manages its own lifecycle
    @ObservationIgnored
    private var displayLinkWrapper: DisplayLinkWrapper?

    /// Frame counter for throttling to ~30fps
    @ObservationIgnored
    private var frameCounter: Int = 0

    /// Number of frames to skip between updates (60fps / 30 target = 2)
    private let framesPerUpdate: Int = 2

    // MARK: - Callbacks

    /// Called when streaming text should be updated in UI
    @ObservationIgnored
    var onTextUpdate: ((UUID, String) -> Void)?

    /// Called when a new streaming message should be created
    @ObservationIgnored
    var onCreateStreamingMessage: (() -> UUID)?

    /// Called when streaming message should be finalized
    @ObservationIgnored
    var onFinalizeMessage: ((UUID, String) -> Void)?

    /// Called when thinking text updates
    @ObservationIgnored
    var onThinkingUpdate: ((String) -> Void)?

    // MARK: - Lifecycle

    init() {
        setupDisplayLink()
        setupBackgroundObservers()
    }

    private func setupDisplayLink() {
        displayLinkWrapper = DisplayLinkWrapper { [weak self] in
            self?.displayLinkFired()
        }
    }

    private func setupBackgroundObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func appDidEnterBackground() {
        // Pause display link to save battery when backgrounded
        displayLinkWrapper?.isPaused = true
    }

    @objc private func appWillEnterForeground() {
        // Resume only if we have pending content to display
        if !pendingTextDelta.isEmpty && streamingMessageId != nil {
            displayLinkWrapper?.isPaused = false
        }
    }

    /// Called by display link at screen refresh rate
    private func displayLinkFired() {
        frameCounter += 1

        // Only flush every N frames (throttle to ~30 updates/sec)
        guard frameCounter >= framesPerUpdate else { return }
        frameCounter = 0

        flushPendingTextIfNeeded()
    }

    private func flushPendingTextIfNeeded() {
        guard !pendingTextDelta.isEmpty,
              let messageId = streamingMessageId else {
            // Nothing to flush - pause the display link to save battery
            if pendingTextDelta.isEmpty {
                displayLinkWrapper?.isPaused = true
            }
            return
        }

        onTextUpdate?(messageId, streamingText)
        pendingTextDelta = ""
    }

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

        // Accumulate delta (efficient - no timer churn)
        pendingTextDelta += delta
        streamingText += delta

        // Ensure display link is running
        if displayLinkWrapper?.isPaused == true {
            displayLinkWrapper?.isPaused = false
        }

        return true
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

    // MARK: - Flush and Finalize

    /// Flush pending text to UI immediately
    func flushPendingText() {
        guard !pendingTextDelta.isEmpty,
              let messageId = streamingMessageId else { return }

        onTextUpdate?(messageId, streamingText)
        pendingTextDelta = ""
    }

    /// Finalize the current streaming message
    /// Returns the final text content
    func finalizeStreamingMessage() -> String {
        // Flush any pending updates first
        flushPendingText()

        // Pause display link since we're done streaming
        displayLinkWrapper?.isPaused = true

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
        displayLinkWrapper?.isPaused = true

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
        displayLinkWrapper?.isPaused = true

        streamingMessageId = nil
        streamingText = ""
        pendingTextDelta = ""
        thinkingText = ""
    }
}

// MARK: - Display Link Wrapper

/// Wrapper class that owns the CADisplayLink and handles its lifecycle
/// This class is not @MainActor so deinit can properly invalidate the display link
private final class DisplayLinkWrapper {
    private var displayLink: CADisplayLink?
    private let handler: @MainActor () -> Void

    var isPaused: Bool {
        get { displayLink?.isPaused ?? true }
        set { displayLink?.isPaused = newValue }
    }

    @MainActor
    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        setupDisplayLink()
    }

    deinit {
        displayLink?.invalidate()
    }

    @MainActor
    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))

        // Configure for smooth 60fps with ability to drop to 30fps
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 60,
            preferred: 60
        )

        // Add to main run loop in common mode (works during scrolling)
        displayLink?.add(to: .main, forMode: .common)

        // Start paused to save battery - will activate on first delta
        displayLink?.isPaused = true
    }

    @objc private func tick() {
        // We're on main thread (display link always fires on main), safe to call handler
        let handler = self.handler
        MainActor.assumeIsolated {
            handler()
        }
    }
}
