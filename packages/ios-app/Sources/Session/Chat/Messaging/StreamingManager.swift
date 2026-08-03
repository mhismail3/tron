import Foundation
import QuartzCore
import UIKit

// MARK: - Streaming Manager
// Manages text delta batching using CADisplayLink for efficient, battery-friendly updates.
// Typewriter animation smooths bursty SSE token delivery into continuous text flow.

@MainActor @Observable
final class StreamingManager {

    // MARK: - Configuration

    struct Config {
        /// Maximum streaming text size to prevent memory exhaustion (10MB)
        static let maxStreamingTextSize = 10_000_000
        /// Target updates per second (60fps for fluid text appearance)
        static let targetUpdatesPerSecond: Int = 60

        // Typewriter animation constants
        static let baseCharsPerFrame: Int = 4
        static let maxCharsPerFrame: Int = 16
        static let catchUpThreshold: Int = 80
        static let maxCatchUpDepth: Int = 400
    }

    // MARK: - Lifecycle

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Streaming State

    /// Current streaming message ID
    private(set) var streamingMessageId: UUID?

    /// All text received from server (grows in bursts)
    private(set) var receivedText: String = ""

    /// Text currently displayed to user (grows smoothly via typewriter animation)
    @ObservationIgnored
    private(set) var displayedText: String = ""

    /// Character count of displayedText (avoids repeated String.count on large strings)
    @ObservationIgnored
    private(set) var displayedCharCount: Int = 0
    /// Character count of receivedText. `String.count` is linear for extended
    /// grapheme clusters, so the hot path maintains this value incrementally.
    @ObservationIgnored
    private var receivedCharCount: Int = 0
    /// Append-only delta queue consumed from the front without repeatedly
    /// indexing or copying the full growing response.
    @ObservationIgnored
    private var pendingTextChunks: [Substring] = []
    @ObservationIgnored
    private var pendingTextChunkIndex: Int = 0
    @ObservationIgnored
    private var pendingCharCount: Int = 0

    /// Public API — returns full received text for external callsites
    var streamingText: String { receivedText }

    /// Whether currently streaming
    var isStreaming: Bool {
        streamingMessageId != nil
    }

    // MARK: - Scroll Throttling

    /// Version counter for scroll tracking (increments every Nth flush for throttled scrolling)
    private(set) var scrollVersion: Int = 0

    /// Flush counter to derive scrollVersion (not observed by SwiftUI)
    @ObservationIgnored
    private var flushesSinceLastScroll: Int = 0

    /// Number of content flushes between scroll updates (~10fps at 60fps flush rate)
    static let flushesPerScrollUpdate: Int = 6

    // MARK: - Display Link Timer

    /// Display link wrapper that manages its own lifecycle
    @ObservationIgnored
    private var displayLinkWrapper: DisplayLinkWrapper?
    var hasInstalledDisplayLink: Bool { displayLinkWrapper != nil }

    /// Frame counter for throttling to ~30fps
    @ObservationIgnored
    private var frameCounter: Int = 0

    /// Flush every display link tick (60fps content updates for fluid streaming)
    private let framesPerUpdate: Int = 1

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

    // MARK: - Lifecycle

    init() {
        setupBackgroundObservers()
    }

    private func ensureDisplayLink() {
        guard displayLinkWrapper == nil else { return }
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
        displayLinkWrapper?.isPaused = true
    }

    @objc private func appWillEnterForeground() {
        if pendingCharCount > 0 && streamingMessageId != nil {
            ensureDisplayLink()
            displayLinkWrapper?.isPaused = false
        }
    }

    /// Called by display link at screen refresh rate
    private func displayLinkFired() {
        frameCounter += 1

        guard frameCounter >= framesPerUpdate else { return }
        frameCounter = 0

        flushPendingTextIfNeeded()
    }

    func flushPendingTextIfNeeded() {
        guard let messageId = streamingMessageId else {
            if pendingCharCount == 0 {
                displayLinkWrapper?.isPaused = true
            }
            return
        }

        let bufferDepth = pendingCharCount
        guard bufferDepth > 0 else {
            displayLinkWrapper?.isPaused = true
            return
        }

        // Adaptive drain rate
        let charsThisFrame: Int
        if bufferDepth <= Config.catchUpThreshold {
            charsThisFrame = Config.baseCharsPerFrame
        } else if bufferDepth >= Config.maxCatchUpDepth {
            charsThisFrame = Config.maxCharsPerFrame
        } else {
            let ratio = Double(bufferDepth - Config.catchUpThreshold)
                       / Double(Config.maxCatchUpDepth - Config.catchUpThreshold)
            charsThisFrame = Config.baseCharsPerFrame
                           + Int(ratio * Double(Config.maxCharsPerFrame - Config.baseCharsPerFrame))
        }

        let drainedText = drainPendingText(maxCharacters: charsThisFrame)
        displayedText.append(contentsOf: drainedText)
        displayedCharCount += drainedText.count

        onTextUpdate?(messageId, displayedText)

        flushesSinceLastScroll += 1
        if flushesSinceLastScroll >= Self.flushesPerScrollUpdate {
            flushesSinceLastScroll = 0
            scrollVersion += 1
        }
    }

    // MARK: - Text Delta Handling

    /// Handle incoming text delta
    /// Returns false if backpressure limit reached
    @discardableResult
    func handleTextDelta(_ delta: String) -> Bool {
        let deltaCharCount = delta.count
        guard receivedCharCount + deltaCharCount < Config.maxStreamingTextSize else {
            return false
        }

        let effectiveDelta: String
        if receivedText.isEmpty {
            effectiveDelta = String(delta.drop(while: \.isNewline))
            guard !effectiveDelta.isEmpty else { return true }
        } else {
            effectiveDelta = delta
        }

        if streamingMessageId == nil {
            if let createMessage = onCreateStreamingMessage {
                streamingMessageId = createMessage()
            }
        }

        receivedText += effectiveDelta
        let effectiveCharCount = effectiveDelta.count
        receivedCharCount += effectiveCharCount
        pendingCharCount += effectiveCharCount
        pendingTextChunks.append(effectiveDelta[...])

        ensureDisplayLink()
        displayLinkWrapper?.isPaused = false

        return true
    }

    // MARK: - Flush and Finalize

    /// Snap all received text to display immediately
    func flushPendingText() {
        guard let messageId = streamingMessageId else { return }
        guard pendingCharCount > 0 else { return }

        displayedText = receivedText
        displayedCharCount = receivedCharCount
        clearPendingText()
        onTextUpdate?(messageId, displayedText)

        flushesSinceLastScroll = 0
        scrollVersion += 1
    }

    /// Finalize the current streaming message
    /// Returns the final text content.
    ///
    /// INVARIANT: the trimming here (`.whitespacesAndNewlines`) MUST
    /// match `AssistantMessagePayload.textContent` in
    /// MessagePayloads.swift so the live-finalized text and the
    /// reconstructed text for the same assistant message converge.
    /// Guarded by `TextStreamConvergenceTests`.
    func finalizeStreamingMessage() -> String {
        flushPendingText()
        releaseDisplayLink()

        guard let messageId = streamingMessageId else { return "" }

        let finalText = receivedText.trimmingCharacters(in: .whitespacesAndNewlines)

        onFinalizeMessage?(messageId, finalText)

        streamingMessageId = nil
        receivedText = ""
        receivedCharCount = 0
        displayedText = ""
        displayedCharCount = 0
        clearPendingText()
        return finalText
    }

    /// Cancel current streaming without finalizing
    func cancelStreaming() {
        releaseDisplayLink()

        streamingMessageId = nil
        receivedText = ""
        receivedCharCount = 0
        displayedText = ""
        displayedCharCount = 0
        clearPendingText()
        scrollVersion = 0
        flushesSinceLastScroll = 0
    }

    /// Finish projecting any accepted deltas and release the screen-refresh
    /// resource when the owning chat is no longer mounted. Streaming identity
    /// remains intact so a transient SwiftUI disappearance does not erase
    /// recoverable in-flight state.
    func suspendDisplayUpdates() {
        flushPendingText()
        releaseDisplayLink()
    }

    // MARK: - State Queries

    var isApproachingLimit: Bool {
        receivedCharCount > Config.maxStreamingTextSize * 8 / 10
    }

    var currentTextLength: Int {
        receivedCharCount
    }

    var remainingCapacity: Int {
        Config.maxStreamingTextSize - receivedCharCount
    }

    // MARK: - In-Progress Session Handling

    func catchUpToInProgress(existingText: String, messageId: UUID) {
        streamingMessageId = messageId
        receivedText = existingText
        receivedCharCount = existingText.count
        displayedText = existingText
        displayedCharCount = existingText.count
        clearPendingText()

        onTextUpdate?(messageId, displayedText)
        scrollVersion += 1
    }

    // MARK: - Reset

    func reset() {
        releaseDisplayLink()

        streamingMessageId = nil
        receivedText = ""
        receivedCharCount = 0
        displayedText = ""
        displayedCharCount = 0
        clearPendingText()
        scrollVersion = 0
        flushesSinceLastScroll = 0
    }

    private func releaseDisplayLink() {
        displayLinkWrapper?.invalidate()
        displayLinkWrapper = nil
    }

    private func drainPendingText(maxCharacters: Int) -> String {
        var remaining = min(maxCharacters, pendingCharCount)
        var drained = ""
        drained.reserveCapacity(remaining)
        while remaining > 0, pendingTextChunkIndex < pendingTextChunks.count {
            let available = pendingTextChunks[pendingTextChunkIndex].count
            let amount = min(remaining, available)
            let prefix = pendingTextChunks[pendingTextChunkIndex].prefix(amount)
            drained.append(contentsOf: prefix)
            pendingTextChunks[pendingTextChunkIndex].removeFirst(amount)
            pendingCharCount -= amount
            remaining -= amount
            if pendingTextChunks[pendingTextChunkIndex].isEmpty {
                pendingTextChunkIndex += 1
            }
        }
        if pendingTextChunkIndex >= 64 {
            pendingTextChunks.removeFirst(pendingTextChunkIndex)
            pendingTextChunkIndex = 0
        }
        return drained
    }

    private func clearPendingText() {
        pendingTextChunks.removeAll(keepingCapacity: true)
        pendingTextChunkIndex = 0
        pendingCharCount = 0
    }
}

// MARK: - Display Link Wrapper

/// Wrapper class that owns the CADisplayLink and handles its lifecycle
/// This class is not @MainActor so deinit can properly invalidate the display link
private final class DisplayLinkWrapper {
    private var displayLink: CADisplayLink?
    private var target: DisplayLinkTarget?
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
        invalidate()
    }

    @MainActor
    private func setupDisplayLink() {
        let target = DisplayLinkTarget(owner: self)
        self.target = target
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))

        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 60,
            preferred: 60
        )

        displayLink?.add(to: .main, forMode: .common)
        displayLink?.isPaused = true
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        target = nil
    }

    fileprivate func tick() {
        let handler = self.handler
        MainActor.assumeIsolated {
            handler()
        }
    }
}

/// CADisplayLink retains its target. The proxy must never retain the wrapper,
/// otherwise the run loop owns a permanent target cycle after a transient chat
/// state value is discarded.
private final class DisplayLinkTarget: NSObject {
    weak var owner: DisplayLinkWrapper?

    init(owner: DisplayLinkWrapper) {
        self.owner = owner
    }

    @objc func tick() {
        owner?.tick()
    }
}
