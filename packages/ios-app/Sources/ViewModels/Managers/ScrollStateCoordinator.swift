import SwiftUI

/// Simplified scroll state coordinator for ChatView
/// Tracks whether user is "following" (auto-scroll on new content) or "reviewing" (scrolled up)
@Observable
@available(iOS 17.0, *)
@MainActor
final class ScrollStateCoordinator {

    // MARK: - State

    /// Current scroll mode
    enum Mode: Equatable {
        case following    // Auto-scroll to bottom on new content
        case reviewing    // User scrolled up, preserve position
    }

    private(set) var mode: Mode = .following
    private(set) var hasUnreadContent = false

    // MARK: - Internal

    /// Grace period after explicit user actions to prevent accidental mode switches
    private var graceUntil: Date = .distantPast
    private let gracePeriod: TimeInterval = 0.5

    // MARK: - User Actions

    /// Call when user sends a new message - always scroll to bottom
    func userSentMessage() {
        mode = .following
        hasUnreadContent = false
        graceUntil = Date().addingTimeInterval(gracePeriod)
    }

    /// Call when user taps "scroll to bottom" button
    func userTappedScrollToBottom() {
        mode = .following
        hasUnreadContent = false
        graceUntil = Date().addingTimeInterval(gracePeriod)
    }

    /// Call when user explicitly scrolls (via drag gesture)
    /// Only switch to reviewing if scrolled significantly
    func userDidScroll(isNearBottom: Bool) {
        guard Date() > graceUntil else { return }

        if isNearBottom {
            if mode == .reviewing {
                mode = .following
                hasUnreadContent = false
            }
        } else {
            if mode == .following {
                mode = .reviewing
            }
        }
    }

    // MARK: - Content Changes

    /// Call when new content is added at bottom
    func contentAdded() {
        if mode == .reviewing {
            hasUnreadContent = true
        }
    }

    /// Call when processing ends
    func processingEnded() {
        hasUnreadContent = false
    }

    // MARK: - Navigation

    /// Call when navigating to a specific message (e.g., deep link)
    /// Switches to reviewing mode to prevent auto-scroll from interfering
    func scrollToTarget(messageId: UUID, using proxy: ScrollViewProxy?) {
        mode = .reviewing
        hasUnreadContent = false
        graceUntil = Date().addingTimeInterval(gracePeriod)

        withAnimation(.easeOut(duration: 0.3)) {
            proxy?.scrollTo(messageId, anchor: .center)
        }
    }

    // MARK: - History Loading

    /// Item ID to anchor during prepend operations
    private var anchoredItemId: UUID?

    /// Call BEFORE loading older messages to preserve scroll position
    func willPrependHistory(firstVisibleId: UUID?) {
        anchoredItemId = firstVisibleId
    }

    /// Call AFTER older messages are loaded - scrolls back to anchored position
    func didPrependHistory(using proxy: ScrollViewProxy?) {
        if let id = anchoredItemId {
            // Scroll back to where user was before prepend
            proxy?.scrollTo(id, anchor: .top)
            anchoredItemId = nil
        }
    }

    // MARK: - Query

    var shouldAutoScroll: Bool {
        mode == .following
    }

    var shouldShowScrollToBottomButton: Bool {
        mode == .reviewing && hasUnreadContent
    }
}
