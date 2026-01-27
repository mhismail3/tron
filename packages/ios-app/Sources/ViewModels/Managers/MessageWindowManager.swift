import Foundation
import SwiftUI

// MARK: - Message Window Manager
// Manages virtual scrolling with lazy loading and memory-bounded message window

@Observable
@MainActor
final class MessageWindowManager {

    // MARK: - Configuration

    struct Config {
        /// Number of messages to load initially
        static let initialLoadCount = 50
        /// Number of additional messages to load on scroll-up
        static let loadMoreCount = 30
        /// Maximum messages to keep in memory
        static let maxWindowSize = 150
        /// Threshold to trigger pruning (when window exceeds this)
        static let unloadThreshold = 100
        /// Buffer of messages to preload ahead of scroll position
        static let preloadBuffer = 20
    }

    // MARK: - State

    /// All message IDs in chronological order (full history reference)
    private var allMessageIds: [UUID] = []

    /// Currently loaded messages (windowed subset)
    private var loadedMessages: [UUID: ChatMessage] = [:]

    /// Window bounds into allMessageIds
    private var windowStart: Int = 0
    private var windowEnd: Int = 0

    /// Estimated heights for unloaded messages (for scroll position preservation)
    private var estimatedHeights: [UUID: CGFloat] = [:]

    /// Default estimated height for messages
    private let defaultEstimatedHeight: CGFloat = 80

    /// Data source for loading messages
    weak var dataSource: MessageWindowDataSource?

    // MARK: - Published State

    private(set) var hasMoreOlder: Bool = false
    private(set) var hasMoreNewer: Bool = false
    private(set) var isLoadingOlder: Bool = false
    private(set) var isLoadingNewer: Bool = false

    // MARK: - Computed Properties

    /// Currently windowed messages for display (in chronological order)
    var windowedMessages: [ChatMessage] {
        guard windowStart < allMessageIds.count else { return [] }
        let endIndex = min(windowEnd, allMessageIds.count)
        return (windowStart..<endIndex).compactMap { index in
            loadedMessages[allMessageIds[index]]
        }
    }

    /// Total message count
    var totalCount: Int {
        allMessageIds.count
    }

    /// Current window size
    var currentWindowSize: Int {
        windowEnd - windowStart
    }

    /// Placeholder height for unloaded region above window
    var topPlaceholderHeight: CGFloat {
        guard windowStart > 0 else { return 0 }
        return (0..<windowStart).reduce(0) { total, index in
            let id = allMessageIds[index]
            return total + (estimatedHeights[id] ?? defaultEstimatedHeight)
        }
    }

    /// Placeholder height for unloaded region below window
    var bottomPlaceholderHeight: CGFloat {
        guard windowEnd < allMessageIds.count else { return 0 }
        return (windowEnd..<allMessageIds.count).reduce(0) { total, index in
            let id = allMessageIds[index]
            return total + (estimatedHeights[id] ?? defaultEstimatedHeight)
        }
    }

    // MARK: - Initialization

    /// Load initial messages from data source
    func loadInitial() async {
        guard let dataSource = dataSource else { return }

        let messages = await dataSource.loadLatestMessages(count: Config.initialLoadCount)

        // Reset state
        allMessageIds = messages.map { $0.id }
        loadedMessages = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        // Window starts at end of loaded messages
        windowStart = max(0, allMessageIds.count - Config.initialLoadCount)
        windowEnd = allMessageIds.count

        hasMoreOlder = await dataSource.hasMoreMessages(before: messages.first?.id)
        hasMoreNewer = false // At most recent
    }

    /// Load older messages (scroll up)
    func loadOlder() async {
        guard !isLoadingOlder, hasMoreOlder, let dataSource = dataSource else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let beforeId = windowStart > 0 ? allMessageIds[windowStart] : allMessageIds.first

        let olderMessages = await dataSource.loadMessages(
            before: beforeId,
            count: Config.loadMoreCount
        )

        guard !olderMessages.isEmpty else {
            hasMoreOlder = false
            return
        }

        // Insert at beginning of allMessageIds
        let newIds = olderMessages.map { $0.id }
        allMessageIds.insert(contentsOf: newIds, at: 0)

        // Add to loaded messages
        for message in olderMessages {
            loadedMessages[message.id] = message
        }

        // Expand window start
        windowStart = 0
        windowEnd += newIds.count

        // Check if more available
        hasMoreOlder = await dataSource.hasMoreMessages(before: olderMessages.first?.id)

        // Prune from bottom if window too large
        pruneIfNeeded(preserveTop: true)
    }

    /// Load newer messages (scroll down, if viewing history)
    func loadNewer() async {
        guard !isLoadingNewer, hasMoreNewer, let dataSource = dataSource else { return }

        isLoadingNewer = true
        defer { isLoadingNewer = false }

        let afterId = windowEnd < allMessageIds.count ? allMessageIds[windowEnd - 1] : allMessageIds.last

        let newerMessages = await dataSource.loadMessages(
            after: afterId,
            count: Config.loadMoreCount
        )

        guard !newerMessages.isEmpty else {
            hasMoreNewer = false
            return
        }

        // Append to allMessageIds
        for message in newerMessages {
            allMessageIds.append(message.id)
            loadedMessages[message.id] = message
        }

        // Expand window end
        windowEnd = allMessageIds.count

        // Check if more available
        hasMoreNewer = await dataSource.hasMoreMessages(after: newerMessages.last?.id)

        // Prune from top if window too large
        pruneIfNeeded(preserveTop: false)
    }

    // MARK: - Streaming/New Messages

    /// Append a new message (from streaming or user input)
    func appendMessage(_ message: ChatMessage) {
        allMessageIds.append(message.id)
        loadedMessages[message.id] = message
        windowEnd = allMessageIds.count

        // Prune from top if window too large
        pruneIfNeeded(preserveTop: false)
    }

    /// Update an existing message (e.g., tool result)
    func updateMessage(_ message: ChatMessage) {
        guard loadedMessages[message.id] != nil else { return }
        loadedMessages[message.id] = message
    }

    /// Remove a message
    func removeMessage(id: UUID) {
        if let index = allMessageIds.firstIndex(of: id) {
            allMessageIds.remove(at: index)

            // Adjust window bounds
            if index < windowStart {
                windowStart = max(0, windowStart - 1)
            }
            if index < windowEnd {
                windowEnd = max(windowStart, windowEnd - 1)
            }
        }

        loadedMessages.removeValue(forKey: id)
        estimatedHeights.removeValue(forKey: id)
    }

    // MARK: - Window Management

    /// Prune messages to stay within memory bounds
    private func pruneIfNeeded(preserveTop: Bool) {
        guard currentWindowSize > Config.unloadThreshold else { return }

        let excess = currentWindowSize - Config.maxWindowSize

        if preserveTop {
            // Prune from bottom (user scrolling up)
            let newEnd = windowEnd - excess
            for i in newEnd..<windowEnd {
                let id = allMessageIds[i]
                // Save estimated height before unloading
                if let message = loadedMessages[id] {
                    estimatedHeights[id] = estimateHeight(for: message)
                }
                loadedMessages.removeValue(forKey: id)
            }
            windowEnd = newEnd
            hasMoreNewer = true
        } else {
            // Prune from top (user at bottom)
            let newStart = windowStart + excess
            for i in windowStart..<newStart {
                let id = allMessageIds[i]
                // Save estimated height before unloading
                if let message = loadedMessages[id] {
                    estimatedHeights[id] = estimateHeight(for: message)
                }
                loadedMessages.removeValue(forKey: id)
            }
            windowStart = newStart
            hasMoreOlder = true
        }
    }

    /// Estimate height for a message (for scroll position preservation)
    private func estimateHeight(for message: ChatMessage) -> CGFloat {
        // Simple heuristic based on content type
        switch message.content {
        case .text(let text):
            // Rough estimate: 20pt per line, ~50 chars per line
            let lines = max(1, text.count / 50)
            return CGFloat(lines * 20 + 40)
        case .toolUse:
            return 100
        case .streaming:
            return 60
        default:
            return defaultEstimatedHeight
        }
    }

    // MARK: - Scroll Position Tracking

    /// Update estimated height after measuring actual rendered height
    func updateEstimatedHeight(for id: UUID, height: CGFloat) {
        estimatedHeights[id] = height
    }

    // MARK: - Reset

    /// Reset all state
    func reset() {
        allMessageIds.removeAll()
        loadedMessages.removeAll()
        estimatedHeights.removeAll()
        windowStart = 0
        windowEnd = 0
        hasMoreOlder = false
        hasMoreNewer = false
        isLoadingOlder = false
        isLoadingNewer = false
    }

    /// Reload with new messages (e.g., after sync)
    func reload(with messages: [ChatMessage]) {
        reset()

        allMessageIds = messages.map { $0.id }

        // Load only the latest window
        let startIndex = max(0, messages.count - Config.initialLoadCount)
        for i in startIndex..<messages.count {
            loadedMessages[messages[i].id] = messages[i]
        }

        windowStart = startIndex
        windowEnd = messages.count
        hasMoreOlder = startIndex > 0
        hasMoreNewer = false
    }
}

// MARK: - Data Source Protocol

@MainActor
protocol MessageWindowDataSource: AnyObject {
    /// Load the most recent messages
    func loadLatestMessages(count: Int) async -> [ChatMessage]

    /// Load messages before a given message ID
    func loadMessages(before id: UUID?, count: Int) async -> [ChatMessage]

    /// Load messages after a given message ID
    func loadMessages(after id: UUID?, count: Int) async -> [ChatMessage]

    /// Check if more messages exist before/after a given ID
    func hasMoreMessages(before id: UUID?) async -> Bool
    func hasMoreMessages(after id: UUID?) async -> Bool
}
