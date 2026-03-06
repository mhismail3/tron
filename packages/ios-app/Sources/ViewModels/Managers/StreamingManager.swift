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
        displayLinkWrapper?.isPaused = true
    }

    @objc private func appWillEnterForeground() {
        if displayedCharCount < receivedText.count && streamingMessageId != nil {
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
            if displayedCharCount >= receivedText.count {
                displayLinkWrapper?.isPaused = true
            }
            return
        }

        let bufferDepth = receivedText.count - displayedCharCount
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

        let newCharCount = min(displayedCharCount + charsThisFrame, receivedText.count)
        let idx = receivedText.index(receivedText.startIndex, offsetBy: newCharCount)
        displayedText = String(receivedText[..<idx])
        displayedCharCount = newCharCount

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
        guard receivedText.count + delta.count < Config.maxStreamingTextSize else {
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

        if displayLinkWrapper?.isPaused == true {
            displayLinkWrapper?.isPaused = false
        }

        return true
    }

    // MARK: - Flush and Finalize

    /// Snap all received text to display immediately
    func flushPendingText() {
        guard let messageId = streamingMessageId else { return }
        guard displayedCharCount < receivedText.count else { return }

        displayedText = receivedText
        displayedCharCount = receivedText.count
        onTextUpdate?(messageId, displayedText)

        flushesSinceLastScroll = 0
        scrollVersion += 1
    }

    /// Finalize the current streaming message
    /// Returns the final text content
    func finalizeStreamingMessage() -> String {
        flushPendingText()
        displayLinkWrapper?.isPaused = true

        guard let messageId = streamingMessageId else { return "" }

        let finalText = receivedText.trimmingCharacters(in: .whitespacesAndNewlines)

        onFinalizeMessage?(messageId, finalText)

        streamingMessageId = nil
        receivedText = ""
        displayedText = ""
        displayedCharCount = 0
        return finalText
    }

    /// Cancel current streaming without finalizing
    func cancelStreaming() {
        displayLinkWrapper?.isPaused = true

        streamingMessageId = nil
        receivedText = ""
        displayedText = ""
        displayedCharCount = 0
        scrollVersion = 0
        flushesSinceLastScroll = 0
    }

    // MARK: - State Queries

    var isApproachingLimit: Bool {
        receivedText.count > Config.maxStreamingTextSize * 8 / 10
    }

    var currentTextLength: Int {
        receivedText.count
    }

    var remainingCapacity: Int {
        Config.maxStreamingTextSize - receivedText.count
    }

    // MARK: - In-Progress Session Handling

    func catchUpToInProgress(existingText: String, messageId: UUID) {
        streamingMessageId = messageId
        receivedText = existingText
        displayedText = existingText
        displayedCharCount = existingText.count

        onTextUpdate?(messageId, displayedText)
        scrollVersion += 1
    }

    // MARK: - Reset

    func reset() {
        displayLinkWrapper?.isPaused = true

        streamingMessageId = nil
        receivedText = ""
        displayedText = ""
        displayedCharCount = 0
        scrollVersion = 0
        flushesSinceLastScroll = 0
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

        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 60,
            preferred: 60
        )

        displayLink?.add(to: .main, forMode: .common)
        displayLink?.isPaused = true
    }

    @objc private func tick() {
        let handler = self.handler
        MainActor.assumeIsolated {
            handler()
        }
    }
}
