import SwiftUI

/// Manages thinking display state for ChatViewModel.
/// Pure state object: handles live streaming, history blocks, and lazy loading for the sheet.
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

    // MARK: - History State (lightweight previews only)

    /// Historical thinking blocks (preview data only, full content loaded on demand)
    private(set) var blocks: [ThinkingBlock] = []

    // MARK: - Sheet State

    /// Whether the thinking detail sheet is displayed
    var showSheet: Bool = false

    /// Currently selected block ID for detail view
    private(set) var selectedBlockId: UUID?

    /// Full content of selected block (single buffer, reused)
    private(set) var loadedFullContent: String = ""

    /// Whether content is being loaded
    private(set) var isLoadingContent: Bool = false

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

        let block = ThinkingBlock(
            eventId: "local_\(UUID().uuidString)",
            turnNumber: currentTurnNumber,
            preview: payload.preview,
            characterCount: payload.characterCount,
            model: currentModel,
            timestamp: Date()
        )

        withAnimation(.easeInOut(duration: 0.2)) {
            blocks.append(block)
        }

        isStreaming = false
        // Keep currentText until turn actually ends so caption remains visible
        return payload
    }

    /// Clear current streaming state (called on agent.complete or agent.error)
    func clearCurrentStreaming() {
        currentText = ""
        isStreaming = false
    }

    // MARK: - History Loading

    /// Load thinking history for a session (called on session resume)
    func loadHistory(sessionId: String, database: EventDatabase) async {
        do {
            let loadedBlocks = try database.thinking.getEvents(sessionId: sessionId, previewOnly: true)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.blocks = loadedBlocks
                }
            }
            logger.debug("Loaded \(loadedBlocks.count) thinking blocks for session", category: .session)
        } catch {
            logger.error("Failed to load thinking history: \(error.localizedDescription)", category: .session)
        }
    }

    // MARK: - Lazy Loading for Sheet

    /// Load full content for a block (when user taps to expand in sheet)
    func loadFullContent(blockId: UUID, database: EventDatabase) async {
        // If same block is already selected and loaded, just toggle visibility
        if selectedBlockId == blockId && !loadedFullContent.isEmpty {
            selectedBlockId = nil
            loadedFullContent = ""
            return
        }

        guard let block = blocks.first(where: { $0.id == blockId }) else {
            logger.warning("Block not found: \(blockId)", category: .session)
            return
        }

        isLoadingContent = true
        selectedBlockId = blockId
        loadedFullContent = ""

        do {
            if let content = try database.thinking.getContent(eventId: block.eventId) {
                loadedFullContent = content
            } else {
                loadedFullContent = block.preview
                logger.warning("Full content not found for block \(block.eventId), using preview", category: .session)
            }
        } catch {
            logger.error("Failed to load full content: \(error.localizedDescription)", category: .session)
            loadedFullContent = block.preview
        }

        isLoadingContent = false
    }

    /// Check if a block is currently selected
    func isBlockSelected(_ blockId: UUID) -> Bool {
        selectedBlockId == blockId
    }

    // MARK: - Computed Properties

    /// Caption text (first 3 lines of current streaming thinking)
    var captionText: String {
        guard !currentText.isEmpty else { return "" }

        let lines = currentText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)

        let preview = lines.joined(separator: " ")
        if preview.count > 120 {
            return String(preview.prefix(117)) + "..."
        }
        return preview
    }

    /// Whether the thinking caption should be shown
    /// Shows while streaming AND persists after turn ends (until cleared by next user message)
    var shouldShowCaption: Bool {
        !currentText.isEmpty
    }

    /// Whether there's any thinking content (streaming or history)
    var hasContent: Bool {
        !currentText.isEmpty || !blocks.isEmpty
    }

    // MARK: - Cleanup

    /// Clear all state (for new session)
    func clearAll() {
        currentText = ""
        isStreaming = false
        currentTurnNumber = 0
        currentModel = nil
        blocks.removeAll()
        showSheet = false
        selectedBlockId = nil
        loadedFullContent = ""
        isLoadingContent = false
    }

    /// Clear session-specific state only
    func clearSession() {
        blocks.removeAll()
        selectedBlockId = nil
        loadedFullContent = ""
    }
}
