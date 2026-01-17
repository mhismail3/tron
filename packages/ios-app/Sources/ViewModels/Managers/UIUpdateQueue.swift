import Foundation

// MARK: - UI Update Queue
// Ensures tool calls appear in order and batches UI updates for 60fps

@MainActor
final class UIUpdateQueue {

    // MARK: - Configuration

    struct Config {
        /// Batch interval for coalescing rapid updates (~60fps)
        static let batchIntervalNanos: UInt64 = 16_000_000 // 16ms

        /// Priority ordering for updates
        static let priorityTurnBoundary = 0
        static let priorityToolStart = 1
        static let priorityToolEnd = 2
        static let priorityMessageAppend = 3
        static let priorityTextDelta = 4
    }

    // MARK: - Update Types

    enum UpdateType {
        case turnBoundary(TurnBoundaryData)
        case toolStart(ToolStartData)
        case toolEnd(ToolEndData)
        case messageAppend(MessageAppendData)
        case textDelta(TextDeltaData)

        var priority: Int {
            switch self {
            case .turnBoundary: return Config.priorityTurnBoundary
            case .toolStart: return Config.priorityToolStart
            case .toolEnd: return Config.priorityToolEnd
            case .messageAppend: return Config.priorityMessageAppend
            case .textDelta: return Config.priorityTextDelta
            }
        }
    }

    struct TurnBoundaryData {
        let turnNumber: Int
        let isStart: Bool
    }

    struct ToolStartData {
        let toolCallId: String
        let toolName: String
        let arguments: String
        let timestamp: Date
    }

    struct ToolEndData {
        let toolCallId: String
        let success: Bool
        let result: String
        let durationMs: Int?
    }

    struct MessageAppendData {
        let messageId: UUID
        let role: String
        let content: String
    }

    struct TextDeltaData {
        let delta: String
        let totalLength: Int
    }

    // MARK: - State

    /// Order in which tool calls started (for ordering tool ends)
    private var toolCallOrder: [String] = []
    /// Set of completed tool call IDs
    private var completedTools: Set<String> = []
    /// Pending tool end updates waiting for earlier tools to complete
    private var pendingToolResults: [String: ToolEndData] = [:]

    /// Queue of pending updates
    private var pendingUpdates: [UpdateType] = []
    /// Batch processing task
    private var batchTask: Task<Void, Never>?

    /// Callback for processing batched updates
    var onProcessUpdates: (([UpdateType]) -> Void)?

    // MARK: - Tool Ordering

    /// Register a tool call start (establishes ordering)
    func enqueueToolStart(_ data: ToolStartData) {
        toolCallOrder.append(data.toolCallId)
        enqueue(.toolStart(data))
    }

    /// Register a tool call end (may be queued if earlier tools incomplete)
    func enqueueToolEnd(_ data: ToolEndData) {
        // Check if all earlier tools have completed
        guard let toolIndex = toolCallOrder.firstIndex(of: data.toolCallId) else {
            // Unknown tool - process immediately
            enqueue(.toolEnd(data))
            return
        }

        // Check if all earlier tools are complete
        let earlierTools = toolCallOrder.prefix(toolIndex)
        let allEarlierComplete = earlierTools.allSatisfy { completedTools.contains($0) }

        if allEarlierComplete {
            // Process this tool end and mark as complete
            completedTools.insert(data.toolCallId)
            enqueue(.toolEnd(data))

            // Check if any pending tool ends can now be processed
            processPendingToolEnds()
        } else {
            // Queue for later - earlier tools still running
            pendingToolResults[data.toolCallId] = data
        }
    }

    /// Process any pending tool ends that are now ready
    private func processPendingToolEnds() {
        var processed = true
        while processed {
            processed = false

            for toolCallId in toolCallOrder {
                guard let pending = pendingToolResults[toolCallId] else { continue }

                // Check if all earlier tools are complete
                guard let toolIndex = toolCallOrder.firstIndex(of: toolCallId) else { continue }
                let earlierTools = toolCallOrder.prefix(toolIndex)
                let allEarlierComplete = earlierTools.allSatisfy { completedTools.contains($0) }

                if allEarlierComplete {
                    completedTools.insert(toolCallId)
                    pendingToolResults.removeValue(forKey: toolCallId)
                    enqueue(.toolEnd(pending))
                    processed = true
                }
            }
        }
    }

    // MARK: - General Enqueueing

    /// Enqueue a turn boundary update
    func enqueueTurnBoundary(_ data: TurnBoundaryData) {
        if data.isStart {
            // Reset tool tracking at turn start
            toolCallOrder.removeAll()
            completedTools.removeAll()
            pendingToolResults.removeAll()
        }
        enqueue(.turnBoundary(data))
    }

    /// Enqueue a message append update
    func enqueueMessageAppend(_ data: MessageAppendData) {
        enqueue(.messageAppend(data))
    }

    /// Enqueue a text delta update (coalesced heavily)
    func enqueueTextDelta(_ data: TextDeltaData) {
        // Text deltas are coalesced - replace any pending delta with new total
        pendingUpdates.removeAll { update in
            if case .textDelta = update { return true }
            return false
        }
        enqueue(.textDelta(data))
    }

    /// Core enqueue method
    private func enqueue(_ update: UpdateType) {
        pendingUpdates.append(update)
        scheduleBatchProcessing()
    }

    // MARK: - Batch Processing

    private func scheduleBatchProcessing() {
        guard batchTask == nil else { return }

        batchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Config.batchIntervalNanos)

            guard !pendingUpdates.isEmpty else {
                batchTask = nil
                return
            }

            // Sort by priority and process
            let updates = pendingUpdates.sorted()
            pendingUpdates.removeAll()

            onProcessUpdates?(updates)

            batchTask = nil

            // If more updates arrived during processing, schedule another batch
            if !pendingUpdates.isEmpty {
                scheduleBatchProcessing()
            }
        }
    }

    /// Force flush all pending updates immediately
    func flush() {
        batchTask?.cancel()
        batchTask = nil

        guard !pendingUpdates.isEmpty else { return }

        let updates = pendingUpdates.sorted()
        pendingUpdates.removeAll()

        onProcessUpdates?(updates)
    }

    /// Reset all state (e.g., when leaving session)
    func reset() {
        batchTask?.cancel()
        batchTask = nil
        pendingUpdates.removeAll()
        toolCallOrder.removeAll()
        completedTools.removeAll()
        pendingToolResults.removeAll()
    }

    // MARK: - Debugging

    var pendingCount: Int {
        pendingUpdates.count
    }

    var pendingToolEndCount: Int {
        pendingToolResults.count
    }
}

// MARK: - Comparable Conformance

extension UIUpdateQueue.UpdateType: Comparable {
    static func < (lhs: UIUpdateQueue.UpdateType, rhs: UIUpdateQueue.UpdateType) -> Bool {
        lhs.priority < rhs.priority
    }

    static func == (lhs: UIUpdateQueue.UpdateType, rhs: UIUpdateQueue.UpdateType) -> Bool {
        lhs.priority == rhs.priority
    }
}
