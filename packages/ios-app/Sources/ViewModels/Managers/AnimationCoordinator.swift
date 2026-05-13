import SwiftUI

// MARK: - Animation Coordinator
// Manages pill morph animations, message cascade timing, and capability invocation staggering

@Observable
@MainActor
final class AnimationCoordinator {

    // MARK: - Animation Timing Constants

    struct Timing {
        // Message cascade
        static let cascadeStaggerInterval: UInt64 = 20_000_000 // 20ms per message
        static let cascadeMaxMessages = 50                      // Cap at 1 second total
        static let cascadeSpringResponse: Double = 0.3
        static let cascadeSpringDamping: Double = 0.85

        // Capability invocation stagger
        static let toolStaggerInterval: UInt64 = 80_000_000    // 80ms between tools
        static let toolStaggerCap: UInt64 = 200_000_000        // Max 200ms delay
    }

    // MARK: - Published State

    // Tool stagger state
    private(set) var visibleInvocationIds: Set<String> = []
    private var pendingCapabilityInvocations: [PendingCapabilityInvocation] = []
    private var toolProcessingTask: Task<Void, Never>?

    // Message cascade state
    private(set) var cascadeProgress: Int = 0
    private(set) var totalCascadeMessages: Int = 0
    private var cascadeTask: Task<Void, Never>?

    // MARK: - Tool Call Staggering

    struct PendingCapabilityInvocation {
        let invocationId: String
        let queuedAt: Date
    }

    /// Queue a capability invocation to appear with staggered timing
    /// Tools are immediately made visible (so they always render)
    /// The stagger animation queue is just for the visual appearance timing
    func queueCapabilityInvocationStart(invocationId: String) {
        // CRITICAL: Make tool immediately visible so it always renders
        // This prevents tools from disappearing when visibility is checked
        visibleInvocationIds.insert(invocationId)

        // Also queue for staggered animation effect (purely visual)
        pendingCapabilityInvocations.append(PendingCapabilityInvocation(invocationId: invocationId, queuedAt: Date()))
        processToolQueue()
    }

    /// Mark a capability invocation as complete (for ordering capability ends)
    func markCapabilityInvocationComplete(invocationId: String) {
        visibleInvocationIds.insert(invocationId)
    }

    /// Check if a capability invocation should be visible
    func isToolVisible(_ invocationId: String) -> Bool {
        visibleInvocationIds.contains(invocationId)
    }

    /// Directly mark a tool as visible (for catch-up and historical tools)
    func makeCapabilityInvocationVisible(_ invocationId: String) {
        visibleInvocationIds.insert(invocationId)
    }

    /// Reset tool animation state for new turn (preserves visibility of existing tools)
    /// Called at turn boundaries to reset stagger queue for new capability invocations
    func resetToolState() {
        toolProcessingTask?.cancel()
        toolProcessingTask = nil
        pendingCapabilityInvocations.removeAll()
        // NOTE: Do NOT clear visibleInvocationIds - tools already in messages should stay visible
        // They will be naturally cleaned up when the session ends or view is dismissed
    }

    /// Full reset including visibility (called when leaving session)
    func fullReset() {
        toolProcessingTask?.cancel()
        toolProcessingTask = nil
        pendingCapabilityInvocations.removeAll()
        visibleInvocationIds.removeAll()
    }

    private func processToolQueue() {
        guard toolProcessingTask == nil else { return }

        toolProcessingTask = Task { @MainActor in
            while !pendingCapabilityInvocations.isEmpty {
                let pending = pendingCapabilityInvocations.removeFirst()

                // Calculate stagger delay (capped)
                let staggerDelay = min(
                    Timing.toolStaggerInterval * UInt64(visibleInvocationIds.count),
                    Timing.toolStaggerCap
                )

                if staggerDelay > 0 {
                    try? await Task.sleep(nanoseconds: staggerDelay)
                }

                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    _ = visibleInvocationIds.insert(pending.invocationId)
                }
            }

            toolProcessingTask = nil
        }
    }

    // MARK: - Message Cascade Animation

    /// Whether a cascade animation is currently running
    var isCascading: Bool {
        cascadeTask != nil
    }

    /// Start bottom-up cascade animation for loading session messages.
    /// Messages animate from bottom (newest) to top (oldest), so the user
    /// sees the most recent messages appear first at the scroll position.
    /// - Parameters:
    ///   - totalMessages: Total number of messages to cascade
    ///   - onProgress: Called each time a message becomes visible
    ///   - onComplete: Called when cascade finishes
    func startBottomUpCascade(
        totalMessages: Int,
        onProgress: ((Int) -> Void)? = nil,
        onComplete: (() -> Void)? = nil
    ) {
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
                onProgress?(i)
            }

            // Messages beyond cap appear instantly
            if totalMessages > Timing.cascadeMaxMessages {
                cascadeProgress = totalMessages
            }

            onComplete?()
            cascadeTask = nil
        }
    }

    /// Cancel ongoing cascade animation
    func cancelCascade() {
        cascadeTask?.cancel()
        cascadeTask = nil
    }

    /// Check if a message at index should be visible in bottom-up cascade.
    /// Bottom-up means newest messages (highest indices) become visible first.
    /// - Parameters:
    ///   - index: Message index (0 = oldest)
    ///   - total: Total message count
    /// - Returns: true if message should be visible
    func isCascadeVisibleFromBottom(index: Int, total: Int) -> Bool {
        // Bottom-up: newest messages visible first
        // Message at index i is visible when i >= total - cascadeProgress
        return index >= total - cascadeProgress
    }

    /// Make all messages immediately visible (skip cascade animation).
    /// Used for deep link scenarios where we need instant visibility.
    func makeAllMessagesVisible(count: Int) {
        cascadeTask?.cancel()
        cascadeTask = nil
        cascadeProgress = count
        totalCascadeMessages = count
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
