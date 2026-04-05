import SwiftUI

/// Manages thinking streaming state for ChatViewModel.
/// Pure state object: handles live streaming text accumulation and turn lifecycle.
/// Database persistence is handled by the caller (ChatViewModel+TurnLifecycleContext).
@Observable
@MainActor
final class ThinkingState {

    // MARK: - Live Streaming State

    /// Current streaming thinking text (accumulated during turn)
    private(set) var currentText: String = ""

    /// Whether thinking is currently being streamed
    private(set) var isStreaming: Bool = false

    /// Current turn number for the streaming thinking
    private var currentTurnNumber: Int = 0

    /// Model used for current thinking
    private var currentModel: String?

    // MARK: - Initialization

    init() {}

    // MARK: - Catch-Up Seeding

    /// Seed thinking state from catch-up content so future deltas append correctly
    func seedCatchUpThinking(_ text: String, isStreaming: Bool) {
        currentText = text
        self.isStreaming = isStreaming
    }

    // MARK: - Streaming Methods

    /// Handle incoming thinking delta from streaming
    func handleThinkingDelta(_ delta: String) {
        currentText += delta
        isStreaming = true
    }

    /// Start a new turn for thinking
    func startTurn(_ turnNumber: Int, model: String?) {
        currentText = ""
        isStreaming = false
        currentTurnNumber = turnNumber
        currentModel = model
    }

    /// End the current turn. Returns payload to persist, or nil if no thinking content.
    /// The caller is responsible for persisting the payload to the database.
    func endTurn() -> ThinkingCompletePayload? {
        guard !currentText.isEmpty else {
            isStreaming = false
            return nil
        }

        let payload = ThinkingCompletePayload(
            turnNumber: currentTurnNumber,
            content: currentText,
            model: currentModel
        )

        isStreaming = false
        // Keep currentText until cleared by next turn or clearCurrentStreaming
        return payload
    }

    /// Clear current streaming state (called on agent.complete or agent.error)
    func clearCurrentStreaming() {
        currentText = ""
        isStreaming = false
    }
}
