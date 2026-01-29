import SwiftUI
import UIKit

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

    /// Whether user manually dismissed browser sheet this turn (prevents auto-reopen)
    var userDismissedBrowserThisTurn = false

    /// Whether the browser sheet was auto-dismissed (e.g., agent complete)
    /// Used to avoid treating programmatic dismiss as a user dismissal.
    var autoDismissedBrowserThisTurn = false

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
        userDismissedBrowserThisTurn = false
        autoDismissedBrowserThisTurn = false
    }

    /// Clear all browser state (called when browser session closes)
    func clearAll() {
        browserFrame = nil
        browserStatus = nil
        showBrowserWindow = false
        safariURL = nil
        userDismissedBrowserThisTurn = false
        autoDismissedBrowserThisTurn = false
    }
}
