import Foundation

// MARK: - RenderAppUI Chip Tracking

/// Tracks the state of RenderAppUI chip messages in the chat.
///
/// This consolidates three previously separate dictionaries into one atomic state:
/// - `renderAppUIChipMessageIds` - Which message shows each canvas chip
/// - `pendingUIRenderStarts` - Events that arrived before tool_start
/// - `canvasIdToPlaceholderToolCallId` - Placeholder IDs for early chips
///
/// The race condition this solves:
/// Events can arrive in any order: `ui_render_chunk` before `tool_start`, or vice versa.
/// Each path creates/updates chips differently. This tracker ensures all state changes
/// are atomic and the chip message can be found/updated regardless of event order.
@MainActor
final class RenderAppUIChipTracker {

    // MARK: - Chip State

    /// State for a single RenderAppUI chip
    struct ChipState {
        /// The message ID in the chat messages array
        var messageId: UUID

        /// Current toolCallId (may be placeholder like "pending_canvasId" initially)
        var toolCallId: String

        /// Whether toolCallId is a placeholder (waiting for real tool_start)
        var isPlaceholder: Bool

        /// The canvas ID
        let canvasId: String

        /// Title extracted from arguments
        var title: String?

        /// Pending UI render start event (if ui_render_start arrived before tool_start)
        var pendingRenderStart: UIRenderStartEvent?
    }

    // MARK: - State

    /// All tracked chips by canvasId (single source of truth)
    private(set) var chips: [String: ChipState] = [:]

    // MARK: - Chip Lifecycle

    /// Create a chip from the first ui_render_chunk (before tool_start).
    /// Returns the placeholder toolCallId to use.
    func createChipFromChunk(canvasId: String, messageId: UUID, title: String?) -> String {
        let placeholderToolCallId = "pending_\(canvasId)"

        chips[canvasId] = ChipState(
            messageId: messageId,
            toolCallId: placeholderToolCallId,
            isPlaceholder: true,
            canvasId: canvasId,
            title: title,
            pendingRenderStart: nil
        )

        return placeholderToolCallId
    }

    /// Create a chip from tool_start (no prior chunk).
    func createChipFromToolStart(canvasId: String, messageId: UUID, toolCallId: String, title: String?) {
        chips[canvasId] = ChipState(
            messageId: messageId,
            toolCallId: toolCallId,
            isPlaceholder: false,
            canvasId: canvasId,
            title: title,
            pendingRenderStart: nil
        )
    }

    /// Store a pending ui_render_start event (arrived before tool_start).
    func storePendingRenderStart(_ event: UIRenderStartEvent) {
        // Check if we have a chip for this canvas already
        if var chip = chips[event.canvasId] {
            chip.pendingRenderStart = event
            chips[event.canvasId] = chip
        } else {
            // No chip yet - create a temporary entry with the event
            // This will be completed when createChipFromToolStart is called
            // Actually, we need to track by toolCallId for the legacy path
            // Store in a separate lookup
            pendingRenderStartsByToolCallId[event.toolCallId] = event
        }
    }

    /// Pending render starts stored by toolCallId (for legacy path)
    private var pendingRenderStartsByToolCallId: [String: UIRenderStartEvent] = [:]

    /// Get and remove pending render start for a toolCallId
    func consumePendingRenderStart(toolCallId: String) -> UIRenderStartEvent? {
        pendingRenderStartsByToolCallId.removeValue(forKey: toolCallId)
    }

    /// Update a chip's toolCallId from placeholder to real (when tool_start arrives after chunk).
    /// Returns the old placeholder toolCallId, or nil if chip not found or wasn't placeholder.
    @discardableResult
    func updateToolCallId(canvasId: String, realToolCallId: String) -> String? {
        guard var chip = chips[canvasId], chip.isPlaceholder else {
            return nil
        }

        let oldToolCallId = chip.toolCallId
        chip.toolCallId = realToolCallId
        chip.isPlaceholder = false
        chips[canvasId] = chip

        return oldToolCallId
    }

    // MARK: - Accessors

    /// Get chip state for a canvasId
    func getChip(canvasId: String) -> ChipState? {
        chips[canvasId]
    }

    /// Get message ID for a canvasId
    func getMessageId(canvasId: String) -> UUID? {
        chips[canvasId]?.messageId
    }

    /// Get toolCallId for a canvasId (may be placeholder)
    func getToolCallId(canvasId: String) -> String? {
        chips[canvasId]?.toolCallId
    }

    /// Check if a chip exists for canvasId
    func hasChip(canvasId: String) -> Bool {
        chips[canvasId] != nil
    }

    /// Check if a chip's toolCallId is still a placeholder
    func isPlaceholder(canvasId: String) -> Bool {
        chips[canvasId]?.isPlaceholder ?? false
    }

    // MARK: - Cleanup

    /// Remove a chip (e.g., when turn ends or context cleared)
    func removeChip(canvasId: String) {
        chips.removeValue(forKey: canvasId)
    }

    /// Clear all chip tracking state
    func clearAll() {
        chips.removeAll()
        pendingRenderStartsByToolCallId.removeAll()
    }

    /// Clear chips that were created in the current turn (have placeholder IDs)
    func clearPlaceholders() {
        let placeholderCanvasIds = chips.filter { $0.value.isPlaceholder }.map { $0.key }
        for canvasId in placeholderCanvasIds {
            chips.removeValue(forKey: canvasId)
        }
    }
}
