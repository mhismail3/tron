import Foundation

// MARK: - RenderAppUI Chip Tracking

/// Tracks the state of RenderAppUI chip messages in the chat.
///
/// State Management:
/// - `chips[canvasId]` - Primary index: all chip state keyed by canvasId
/// - `toolCallIdToCanvasId[toolCallId]` - Secondary index: reverse lookup for toolCallId
///
/// The race condition this solves:
/// Events can arrive in any order: `ui_render_chunk` before `tool_start`, or vice versa.
/// Each path creates/updates chips differently. This tracker ensures all state changes
/// are atomic and the chip message can be found/updated regardless of event order.
///
/// ## State Transitions
/// 1. **chunk first**: Creates placeholder chip (messageId set, toolCallId = "pending_X")
/// 2. **tool_start first**: Creates real chip (messageId set, real toolCallId)
/// 3. **render_start first**: Creates pre-chip (messageId nil, stores pendingRenderStart)
/// 4. **render_start after chip**: Stores in chip.pendingRenderStart
@MainActor
final class RenderAppUIChipTracker {

    // MARK: - Chip State

    /// State for a single RenderAppUI chip
    struct ChipState {
        /// The message ID in the chat messages array (nil for pre-chip state)
        var messageId: UUID?

        /// Current toolCallId (may be placeholder like "pending_canvasId" initially)
        var toolCallId: String

        /// Whether toolCallId is a placeholder (waiting for real tool_start)
        var isPlaceholder: Bool

        /// The canvas ID
        let canvasId: String

        /// Title extracted from arguments
        var title: String?

        /// Pending UI render start result (if ui_render_start arrived before tool_start)
        var pendingRenderStart: UIRenderStartPlugin.Result?
    }

    // MARK: - State

    /// Primary index: all chips keyed by canvasId (single source of truth)
    private(set) var chips: [String: ChipState] = [:]

    /// Secondary index: toolCallId → canvasId for reverse lookup
    private var toolCallIdToCanvasId: [String: String] = [:]

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
        toolCallIdToCanvasId[placeholderToolCallId] = canvasId

        return placeholderToolCallId
    }

    /// Create a chip from tool_start (no prior chunk).
    func createChipFromToolStart(canvasId: String, messageId: UUID, toolCallId: String, title: String?) {
        // Check if there's a pre-chip (from render_start that arrived first)
        let existingPending = chips[canvasId]?.pendingRenderStart

        chips[canvasId] = ChipState(
            messageId: messageId,
            toolCallId: toolCallId,
            isPlaceholder: false,
            canvasId: canvasId,
            title: title,
            pendingRenderStart: existingPending
        )
        toolCallIdToCanvasId[toolCallId] = canvasId
    }

    /// Store a pending ui_render_start result (arrived before tool_start).
    func storePendingRenderStart(_ result: UIRenderStartPlugin.Result) {
        if var chip = chips[result.canvasId] {
            // Chip already exists - store pending in chip
            chip.pendingRenderStart = result
            chips[result.canvasId] = chip
        } else {
            // No chip yet - create a "pre-chip" state (messageId nil)
            chips[result.canvasId] = ChipState(
                messageId: nil,
                toolCallId: result.toolCallId,
                isPlaceholder: true,
                canvasId: result.canvasId,
                title: result.title,
                pendingRenderStart: result
            )
            toolCallIdToCanvasId[result.toolCallId] = result.canvasId
        }
    }

    /// Get and remove pending render start for a toolCallId.
    /// Uses secondary index to find canvasId, then looks up in chip.
    func consumePendingRenderStart(toolCallId: String) -> UIRenderStartPlugin.Result? {
        guard let canvasId = toolCallIdToCanvasId[toolCallId],
              var chip = chips[canvasId] else {
            return nil
        }

        let result = chip.pendingRenderStart
        chip.pendingRenderStart = nil
        chips[canvasId] = chip

        // Only remove from secondary index if this was a pre-chip (no real message yet)
        if chip.messageId == nil {
            toolCallIdToCanvasId.removeValue(forKey: toolCallId)
            chips.removeValue(forKey: canvasId)
        }

        return result
    }

    /// Update a chip's toolCallId from placeholder to real (when tool_start arrives after chunk).
    /// Returns the old placeholder toolCallId, or nil if chip not found or wasn't placeholder.
    @discardableResult
    func updateToolCallId(canvasId: String, realToolCallId: String) -> String? {
        guard var chip = chips[canvasId], chip.isPlaceholder else {
            return nil
        }

        let oldToolCallId = chip.toolCallId

        // Update secondary index
        toolCallIdToCanvasId.removeValue(forKey: oldToolCallId)
        toolCallIdToCanvasId[realToolCallId] = canvasId

        // Update chip
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
        if let chip = chips[canvasId] {
            toolCallIdToCanvasId.removeValue(forKey: chip.toolCallId)
        }
        chips.removeValue(forKey: canvasId)
    }

    /// Clear all chip tracking state
    func clearAll() {
        chips.removeAll()
        toolCallIdToCanvasId.removeAll()
    }

    /// Clear chips that were created in the current turn (have placeholder IDs)
    func clearPlaceholders() {
        let placeholderCanvasIds = chips.filter { $0.value.isPlaceholder }.map { $0.key }
        for canvasId in placeholderCanvasIds {
            if let chip = chips[canvasId] {
                toolCallIdToCanvasId.removeValue(forKey: chip.toolCallId)
            }
            chips.removeValue(forKey: canvasId)
        }
    }
}
