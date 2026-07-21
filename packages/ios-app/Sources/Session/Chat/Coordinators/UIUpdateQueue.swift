import Foundation

// MARK: - UI Update Queue
// Batches UI updates for 60fps

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
        case toolInvocationStarted(ToolInvocationStartData)
        case toolInvocationCompleted(ToolInvocationEndData)
        case messageAppend(MessageAppendData)
        case textDelta(TextDeltaData)

        var priority: Int {
            switch self {
            case .turnBoundary: return Config.priorityTurnBoundary
            case .toolInvocationStarted: return Config.priorityToolStart
            case .toolInvocationCompleted: return Config.priorityToolEnd
            case .messageAppend: return Config.priorityMessageAppend
            case .textDelta: return Config.priorityTextDelta
            }
        }
    }

    struct TurnBoundaryData {
        let turnNumber: Int
        let isStart: Bool
    }

    struct ToolInvocationStartData {
        let invocationId: String
        let toolName: String
        let arguments: String
        let timestamp: Date
    }

    struct ToolInvocationEndData {
        let invocationId: String
        let success: Bool
        let result: String
        let durationMs: Int?
        let timestamp: Date
        /// Structured result details from server (tool-specific shape)
        let details: [String: AnyCodable]?
        /// Canonical server failure envelope when the result failed.
        let failure: CanonicalFailurePayload?
        let identity: ToolIdentity

        init(
            invocationId: String,
            success: Bool,
            result: String,
            durationMs: Int?,
            timestamp: Date = Date(),
            details: [String: AnyCodable]?,
            failure: CanonicalFailurePayload? = nil,
            identity: ToolIdentity? = nil
        ) {
            self.invocationId = invocationId
            self.success = success
            self.result = result
            self.durationMs = durationMs
            self.timestamp = timestamp
            self.details = details
            self.failure = failure
            self.identity = identity ?? ToolIdentity()
        }
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

    private struct PendingUpdate {
        let order: UInt64
        let update: UpdateType
    }

    /// Queue of pending updates
    private var pendingUpdates: [PendingUpdate] = []
    /// Monotonic enqueue order. Equal-priority updates use this to preserve
    /// server cursor/arrival order, which keeps parallel tool chips from
    /// jumping into completion order.
    private var nextOrder: UInt64 = 0
    /// Batch processing task
    private var batchTask: Task<Void, Never>?

    /// Callback for processing batched updates
    var onProcessUpdates: (([UpdateType]) -> Void)?

    // MARK: - Tool Enqueueing

    /// Register a tool invocation start
    func enqueueToolInvocationStart(_ data: ToolInvocationStartData) {
        enqueue(.toolInvocationStarted(data))
    }

    /// Register a tool invocation end
    func enqueueToolInvocationEnd(_ data: ToolInvocationEndData) {
        enqueue(.toolInvocationCompleted(data))
    }

    // MARK: - General Enqueueing

    /// Enqueue a turn boundary update
    func enqueueTurnBoundary(_ data: TurnBoundaryData) {
        enqueue(.turnBoundary(data))
    }

    /// Enqueue a message append update
    func enqueueMessageAppend(_ data: MessageAppendData) {
        enqueue(.messageAppend(data))
    }

    /// Enqueue a text delta update (coalesced heavily)
    func enqueueTextDelta(_ data: TextDeltaData) {
        // Text deltas are coalesced - replace any pending delta with new total
        pendingUpdates.removeAll { pending in
            if case .textDelta = pending.update { return true }
            return false
        }
        enqueue(.textDelta(data))
    }

    /// Core enqueue method
    private func enqueue(_ update: UpdateType) {
        pendingUpdates.append(PendingUpdate(order: nextOrder, update: update))
        nextOrder += 1
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

            // Sort by priority, then by stable enqueue order for parallel
            // tool starts/completions with the same priority.
            let updates = pendingUpdates
                .sorted { lhs, rhs in
                    if lhs.update.priority == rhs.update.priority {
                        return lhs.order < rhs.order
                    }
                    return lhs.update.priority < rhs.update.priority
                }
                .map(\.update)
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

        let updates = pendingUpdates
            .sorted { lhs, rhs in
                if lhs.update.priority == rhs.update.priority {
                    return lhs.order < rhs.order
                }
                return lhs.update.priority < rhs.update.priority
            }
            .map(\.update)
        pendingUpdates.removeAll()

        onProcessUpdates?(updates)
    }

    /// Reset all state (e.g., when leaving session)
    func reset() {
        batchTask?.cancel()
        batchTask = nil
        pendingUpdates.removeAll()
        nextOrder = 0
    }

    // MARK: - Debugging

    var pendingCount: Int {
        pendingUpdates.count
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
