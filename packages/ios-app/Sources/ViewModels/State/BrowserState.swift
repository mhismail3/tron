import SwiftUI
import UIKit

/// Tracks how the browser sheet was dismissed during the current turn.
/// Replaces two independent booleans that could enter an invalid both-true state.
enum BrowserDismissal: Sendable, Equatable {
    /// No dismissal has occurred this turn
    case none
    /// User manually dismissed (prevents auto-reopen this turn)
    case userDismissed
    /// Auto-dismissed programmatically (e.g., agent complete)
    case autoDismissed
}

/// Manages browser-related state for ChatViewModel
/// Extracted from ChatViewModel to reduce property sprawl
@Observable
@MainActor
final class BrowserState {
    /// Current browser frame image from screencast
    var browserFrame: UIImage?

    /// Whether to show the browser sheet
    var showBrowserWindow = false

    /// Current browser status from server
    var browserStatus: BrowserGetStatusResult?

    /// How the browser sheet was dismissed this turn (if at all)
    var dismissal: BrowserDismissal = .none

    /// URL to open in native Safari (set by OpenBrowser tool)
    var safariURL: URL?

    /// Whether browser toolbar button should be visible
    /// Shows if we have an active browser status OR a browser frame to display
    var hasBrowserSession: Bool {
        (browserStatus?.hasBrowser ?? false) || browserFrame != nil
    }

    init() {}

    /// Reset turn-specific state (called at turn start)
    func resetForNewTurn() {
        dismissal = .none
    }

    /// Clear all browser state (called when browser session closes)
    func clearAll() {
        browserFrame = nil
        browserStatus = nil
        showBrowserWindow = false
        safariURL = nil
        dismissal = .none
    }
}
