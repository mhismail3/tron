import SwiftUI

/// Manages content resolution and auto-scroll state for ThinkingDetailSheet.
///
/// Resolves display content from two sources:
/// - **Live**: `ThinkingState.currentText` when streaming or text is still populated from the current turn
/// - **Static**: Snapshot string passed when the sheet was opened (fallback for historical blocks)
///
/// Also tracks auto-scroll state: enabled by default during streaming, disabled when the user
/// scrolls up, re-enabled when they scroll back to bottom.
@Observable
@MainActor
final class ThinkingDetailState {

    private let thinkingState: ThinkingState
    private let staticContent: String

    /// Whether auto-scroll is enabled. Disabled when user scrolls up, re-enabled on return to bottom.
    private(set) var autoScrollEnabled: Bool = true

    init(thinkingState: ThinkingState, staticContent: String) {
        self.thinkingState = thinkingState
        self.staticContent = staticContent
    }

    // MARK: - Content Resolution

    /// The content to display. Uses live streaming text when available, falls back to static snapshot.
    var displayContent: String {
        if thinkingState.isStreaming || !thinkingState.currentText.isEmpty {
            return thinkingState.currentText
        }
        return staticContent
    }

    /// Whether thinking is currently being streamed.
    var isActivelyStreaming: Bool { thinkingState.isStreaming }

    /// Whether to show the pulsing streaming indicator in the toolbar.
    var showStreamingIndicator: Bool { thinkingState.isStreaming }

    /// Whether the view should auto-scroll to bottom on content changes.
    /// True only when auto-scroll is enabled AND content is actively streaming.
    var shouldAutoScroll: Bool {
        autoScrollEnabled && thinkingState.isStreaming
    }

    // MARK: - Scroll Actions

    /// Call when the user initiates a scroll gesture (scrolls away from bottom).
    func userDidScroll() {
        autoScrollEnabled = false
    }

    /// Call when the user scrolls back to the bottom of the content.
    func userReturnedToBottom() {
        autoScrollEnabled = true
    }
}
