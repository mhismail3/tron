import SwiftUI

// MARK: - Animation Coordinator
// Manages pill morph animations, message cascade timing, and tool call staggering

@MainActor
final class AnimationCoordinator: ObservableObject {

    // MARK: - Animation Timing Constants

    struct Timing {
        // Pill morph sequence delays
        static let contextPillDelay: UInt64 = 0                // Immediate
        static let modelPillDelay: UInt64 = 200_000_000        // 200ms after context
        static let reasoningPillDelay: UInt64 = 170_000_000    // 170ms after model

        // Message cascade
        static let cascadeStaggerInterval: UInt64 = 20_000_000 // 20ms per message
        static let cascadeMaxMessages = 50                      // Cap at 1 second total
        static let cascadeSpringResponse: Double = 0.3
        static let cascadeSpringDamping: Double = 0.85

        // Tool call stagger
        static let toolStaggerInterval: UInt64 = 80_000_000    // 80ms between tools
        static let toolStaggerCap: UInt64 = 200_000_000        // Max 200ms delay
    }

    // MARK: - Pill Morph Phase State Machine

    enum PillMorphPhase: Int, Comparable {
        case dormant = 0
        case contextPillVisible = 1
        case modelPillVisible = 2
        case reasoningPillVisible = 3

        static func < (lhs: PillMorphPhase, rhs: PillMorphPhase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Published State

    @Published private(set) var currentPhase: PillMorphPhase = .dormant
    @Published private(set) var supportsReasoning: Bool = false

    // Tool stagger state
    @Published private(set) var visibleToolCallIds: Set<String> = []
    private var pendingToolCalls: [PendingToolCall] = []
    private var toolProcessingTask: Task<Void, Never>?

    // Message cascade state
    @Published private(set) var cascadeProgress: Int = 0
    @Published private(set) var totalCascadeMessages: Int = 0
    private var cascadeTask: Task<Void, Never>?

    // MARK: - Computed Visibility Properties

    var showContextPill: Bool {
        currentPhase.rawValue >= PillMorphPhase.contextPillVisible.rawValue
    }

    var showModelPill: Bool {
        currentPhase.rawValue >= PillMorphPhase.modelPillVisible.rawValue
    }

    var showReasoningPill: Bool {
        currentPhase.rawValue >= PillMorphPhase.reasoningPillVisible.rawValue && supportsReasoning
    }

    // MARK: - Pill Morph Sequence

    /// Start the chained pill morph animation sequence
    /// Pills appear sequentially: context → model → reasoning (if supported)
    func startPillMorphSequence(supportsReasoning: Bool) {
        self.supportsReasoning = supportsReasoning
        currentPhase = .dormant

        Task { @MainActor in
            // Context pill appears immediately
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                currentPhase = .contextPillVisible
            }

            // Model pill morphs from context pill after delay
            try? await Task.sleep(nanoseconds: Timing.modelPillDelay)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                currentPhase = .modelPillVisible
            }

            // Reasoning pill morphs from model pill (if supported)
            if supportsReasoning {
                try? await Task.sleep(nanoseconds: Timing.reasoningPillDelay)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    currentPhase = .reasoningPillVisible
                }
            }
        }
    }

    /// Reset pill state to dormant (e.g., when leaving chat)
    func resetPillState() {
        currentPhase = .dormant
        supportsReasoning = false
    }

    /// Set pills visible immediately without animation (for resumed sessions with existing data)
    /// Call this instead of startPillMorphSequence when loading a session that already has content
    func setPillsVisibleImmediately(supportsReasoning: Bool) {
        self.supportsReasoning = supportsReasoning
        // Set to final state immediately - no animation needed for resumed sessions
        currentPhase = supportsReasoning ? .reasoningPillVisible : .modelPillVisible
    }

    /// Update reasoning support (e.g., when model changes)
    func updateReasoningSupport(_ supports: Bool) {
        let wasSupported = supportsReasoning
        supportsReasoning = supports

        // If switching to a model that supports reasoning while pills are visible
        if supports && !wasSupported && currentPhase >= .modelPillVisible {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Timing.reasoningPillDelay)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    currentPhase = .reasoningPillVisible
                }
            }
        } else if !supports && wasSupported {
            // Hide reasoning pill when switching to non-reasoning model
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                if currentPhase == .reasoningPillVisible {
                    currentPhase = .modelPillVisible
                }
            }
        }
    }

    // MARK: - Tool Call Staggering

    struct PendingToolCall {
        let toolCallId: String
        let queuedAt: Date
    }

    /// Queue a tool call to appear with staggered timing
    /// Tools are immediately made visible (so they always render)
    /// The stagger animation queue is just for the visual appearance timing
    func queueToolStart(toolCallId: String) {
        // CRITICAL: Make tool immediately visible so it always renders
        // This prevents tools from disappearing when visibility is checked
        visibleToolCallIds.insert(toolCallId)

        // Also queue for staggered animation effect (purely visual)
        pendingToolCalls.append(PendingToolCall(toolCallId: toolCallId, queuedAt: Date()))
        processToolQueue()
    }

    /// Mark a tool call as complete (for ordering tool ends)
    func markToolComplete(toolCallId: String) {
        visibleToolCallIds.insert(toolCallId)
    }

    /// Check if a tool call should be visible
    func isToolVisible(_ toolCallId: String) -> Bool {
        visibleToolCallIds.contains(toolCallId)
    }

    /// Directly mark a tool as visible (for catch-up and historical tools)
    func makeToolVisible(_ toolCallId: String) {
        visibleToolCallIds.insert(toolCallId)
    }

    /// Reset tool animation state for new turn (preserves visibility of existing tools)
    /// Called at turn boundaries to reset stagger queue for new tool calls
    func resetToolState() {
        toolProcessingTask?.cancel()
        toolProcessingTask = nil
        pendingToolCalls.removeAll()
        // NOTE: Do NOT clear visibleToolCallIds - tools already in messages should stay visible
        // They will be naturally cleaned up when the session ends or view is dismissed
    }

    /// Full reset including visibility (called when leaving session)
    func fullReset() {
        toolProcessingTask?.cancel()
        toolProcessingTask = nil
        pendingToolCalls.removeAll()
        visibleToolCallIds.removeAll()
    }

    private func processToolQueue() {
        guard toolProcessingTask == nil else { return }

        toolProcessingTask = Task { @MainActor in
            while !pendingToolCalls.isEmpty {
                let pending = pendingToolCalls.removeFirst()

                // Calculate stagger delay (capped)
                let staggerDelay = min(
                    Timing.toolStaggerInterval * UInt64(visibleToolCallIds.count),
                    Timing.toolStaggerCap
                )

                if staggerDelay > 0 {
                    try? await Task.sleep(nanoseconds: staggerDelay)
                }

                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    visibleToolCallIds.insert(pending.toolCallId)
                }
            }

            toolProcessingTask = nil
        }
    }

    // MARK: - Message Cascade Animation

    /// Start cascade animation for loading session messages
    /// Messages animate in from bottom with staggered timing
    func startMessageCascade(totalMessages: Int, completion: @escaping (Int) -> Void) {
        cascadeTask?.cancel()
        cascadeProgress = 0
        totalCascadeMessages = min(totalMessages, Timing.cascadeMaxMessages)

        cascadeTask = Task { @MainActor in
            for i in 0..<totalCascadeMessages {
                guard !Task.isCancelled else { break }

                try? await Task.sleep(nanoseconds: Timing.cascadeStaggerInterval)

                withAnimation(.spring(
                    response: Timing.cascadeSpringResponse,
                    dampingFraction: Timing.cascadeSpringDamping
                )) {
                    cascadeProgress = i + 1
                }
                completion(i)
            }

            // Any messages beyond cap appear instantly
            if totalMessages > Timing.cascadeMaxMessages {
                cascadeProgress = totalMessages
                completion(totalMessages - 1)
            }

            cascadeTask = nil
        }
    }

    /// Cancel ongoing cascade animation
    func cancelCascade() {
        cascadeTask?.cancel()
        cascadeTask = nil
    }

    /// Check if a message at index should be visible in cascade
    func isCascadeVisible(index: Int) -> Bool {
        index < cascadeProgress
    }

    // MARK: - Animation Helpers

    /// Standard pill animation
    static var pillAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.86)
    }

    /// Tool appearance animation
    static var toolAnimation: Animation {
        .spring(response: 0.35, dampingFraction: 0.8)
    }

    /// Message cascade animation
    static var cascadeAnimation: Animation {
        .spring(response: Timing.cascadeSpringResponse, dampingFraction: Timing.cascadeSpringDamping)
    }
}
