import SwiftUI

/// Manages thinking display state for ChatViewModel
/// Handles live streaming, persistence, history, and lazy loading for the sheet
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

    // MARK: - Dependencies

    private weak var eventDatabase: EventDatabase?
    private var sessionId: String?

    // MARK: - Initialization

    init(eventDatabase: EventDatabase? = nil) {
        self.eventDatabase = eventDatabase
    }

    /// Set the event database reference (called from ChatViewModel)
    func setEventDatabase(_ database: EventDatabase?, sessionId: String?) {
        self.eventDatabase = database
        self.sessionId = sessionId
    }

    // MARK: - Streaming Methods

    /// Handle incoming thinking delta from streaming
    func handleThinkingDelta(_ delta: String) {
        currentText += delta
        isStreaming = true
    }

    /// Start a new turn for thinking
    func startTurn(_ turnNumber: Int, model: String?) {
        // If there's accumulated thinking from previous turn, it should already be persisted
        // Clear streaming state for new turn
        currentText = ""
        isStreaming = false
        currentTurnNumber = turnNumber
        currentModel = model
    }

    /// End the current turn - persist thinking to database
    /// Called from ChatViewModel when agent.turn_end is received
    func endTurn() async {
        // Only persist if there's actual thinking content
        guard !currentText.isEmpty else {
            isStreaming = false
            return
        }

        // Create payload and persist
        let payload = ThinkingCompletePayload(
            turnNumber: currentTurnNumber,
            content: currentText,
            model: currentModel
        )

        // Create block for local display immediately
        let block = ThinkingBlock(
            eventId: "local_\(UUID().uuidString)",  // Temporary ID until synced
            turnNumber: currentTurnNumber,
            preview: payload.preview,
            characterCount: payload.characterCount,
            model: currentModel,
            timestamp: Date()
        )

        // Add to history
        withAnimation(.easeInOut(duration: 0.2)) {
            blocks.append(block)
        }

        // Persist to database via event insertion
        await persistThinkingEvent(payload)

        // Clear streaming state
        isStreaming = false
        // Keep currentText until turn actually ends so caption remains visible
    }

    /// Persist thinking complete event to database
    private func persistThinkingEvent(_ payload: ThinkingCompletePayload) async {
        guard let database = eventDatabase,
              let sessionId = sessionId else {
            logger.warning("Cannot persist thinking - no database or session", category: .session)
            return
        }

        // Get workspace ID from session
        guard let session = try? database.getSession(sessionId) else {
            logger.warning("Cannot persist thinking - session not found", category: .session)
            return
        }

        // Create event
        let event = SessionEvent(
            id: "evt_thinking_\(UUID().uuidString)",
            parentId: nil,  // Will be set by event chain
            sessionId: sessionId,
            workspaceId: session.workspaceId,
            type: "stream.thinking_complete",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 0,  // Will be determined by insert order
            payload: payload.toDictionary().mapValues { AnyCodable($0) }
        )

        do {
            try database.insertEvent(event)
            logger.debug("Persisted thinking event for turn \(payload.turnNumber)", category: .session)
        } catch {
            logger.error("Failed to persist thinking event: \(error.localizedDescription)", category: .session)
        }
    }

    /// Clear current streaming state (called on agent.complete or agent.error)
    func clearCurrentStreaming() {
        currentText = ""
        isStreaming = false
    }

    // MARK: - History Loading

    /// Load thinking history for a session (called on session resume)
    func loadHistory(sessionId: String) async {
        self.sessionId = sessionId

        guard let database = eventDatabase else {
            logger.warning("Cannot load thinking history - no database", category: .session)
            return
        }

        do {
            let loadedBlocks = try database.getThinkingEvents(sessionId: sessionId, previewOnly: true)
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
    func loadFullContent(blockId: UUID) async {
        // If same block is already selected and loaded, just toggle visibility
        if selectedBlockId == blockId && !loadedFullContent.isEmpty {
            // Deselect
            selectedBlockId = nil
            loadedFullContent = ""
            return
        }

        // Find the block
        guard let block = blocks.first(where: { $0.id == blockId }) else {
            logger.warning("Block not found: \(blockId)", category: .session)
            return
        }

        // Clear previous content and set loading state
        isLoadingContent = true
        selectedBlockId = blockId
        loadedFullContent = ""

        // Load from database
        guard let database = eventDatabase else {
            isLoadingContent = false
            logger.warning("Cannot load full content - no database", category: .session)
            return
        }

        do {
            if let content = try database.getThinkingContent(eventId: block.eventId) {
                loadedFullContent = content
            } else {
                // Fallback to preview if full content not found
                loadedFullContent = block.preview
                logger.warning("Full content not found for block \(block.eventId), using preview", category: .session)
            }
        } catch {
            logger.error("Failed to load full content: \(error.localizedDescription)", category: .session)
            loadedFullContent = block.preview  // Fallback
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
        sessionId = nil
    }

    /// Clear session-specific state only
    func clearSession() {
        blocks.removeAll()
        selectedBlockId = nil
        loadedFullContent = ""
    }
}
