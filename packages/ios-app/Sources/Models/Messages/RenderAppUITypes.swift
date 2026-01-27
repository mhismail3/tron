import Foundation

// MARK: - RenderAppUI Types

/// Status for a RenderAppUI canvas render
enum RenderAppUIStatus: String, Equatable {
    case rendering
    case complete
    case error
}

/// Data for tracking a RenderAppUI tool call (rendered as a chip in chat)
struct RenderAppUIChipData: Equatable {
    /// The tool call ID from RenderAppUI (var to allow updating placeholder → real ID)
    var toolCallId: String
    /// Canvas ID for the rendered UI
    let canvasId: String
    /// Title of the rendered app
    let title: String?
    /// Current status
    var status: RenderAppUIStatus
    /// Error message (when failed)
    var errorMessage: String?

    /// Display title (falls back to "App" if no title)
    var displayTitle: String {
        title ?? "App"
    }

    /// Whether this chip should be tappable (rendering and complete chips are tappable)
    /// Rendering: tap to watch generation in real time
    /// Complete: tap to view the rendered UI
    /// Error: not tappable (nothing to show)
    var isTappable: Bool {
        status == .rendering || status == .complete
    }
}
