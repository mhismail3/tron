import SwiftUI
import QuartzCore

/// Unified scroll state machine for ChatView
/// Replaces fragmented scroll state (@State vars) with explicit state machine
/// Handles content mutations (prepend vs append) correctly
@available(iOS 17.0, *)
@MainActor
final class ScrollStateCoordinator: ObservableObject {

    // MARK: - State Machine

    /// Current scroll mode
    enum Mode: Equatable {
        case following    // Auto-scroll to bottom on new content
        case reviewing    // User reading history, preserve position
        case loading      // Loading older messages, preserve position
    }

    /// Type of content mutation for appropriate scroll handling
    enum ContentMutation {
        case appendNew           // New message at bottom
        case prependHistory      // Older messages at top
        case updateExisting      // Message content changed (streaming)
        case initialLoad         // First load
    }

    // MARK: - Published State

    @Published private(set) var mode: Mode = .following
    @Published private(set) var hasUnreadContent = false

    /// Bidirectional scroll position binding for iOS 17+
    /// Use with .scrollPosition($scrollCoordinator.scrollPosition)
    @Published var scrollPosition = ScrollPosition(edge: .bottom)

    // MARK: - Internal State

    /// Grace period after explicit user actions to prevent gesture detection
    private var graceUntil: Date = .distantPast

    /// Item ID to anchor during prepend operations
    private var anchoredItemId: UUID?

    /// Threshold for "at bottom" detection
    private let atBottomThreshold: CGFloat = 50

    /// Grace period duration after user actions
    private let gracePeriod: TimeInterval = 0.8

    // MARK: - Scroll Debouncing

    /// Last time a scroll command was issued (for debouncing)
    private var lastScrollTime: CFTimeInterval = 0

    /// Minimum interval between scroll commands (~30fps matches display link)
    private let scrollDebounceInterval: CFTimeInterval = 1.0 / 30.0

    // MARK: - Content Mutation Protocol

    /// Call BEFORE modifying the messages array
    /// For prepend operations, captures the first visible item ID
    func willMutateContent(_ mutation: ContentMutation, firstVisibleId: UUID? = nil) {
        switch mutation {
        case .prependHistory:
            anchoredItemId = firstVisibleId
            mode = .loading
        case .appendNew, .updateExisting, .initialLoad:
            break
        }
    }

    /// Call AFTER modifying the messages array
    /// Handles scroll position based on mutation type
    func didMutateContent(_ mutation: ContentMutation) {
        switch mutation {
        case .prependHistory:
            // Restore position to anchored item after prepend
            if let id = anchoredItemId {
                // Use withAnimation to ensure smooth transition
                withAnimation(.easeOut(duration: 0.1)) {
                    scrollPosition.scrollTo(id: id, anchor: .top)
                }
                anchoredItemId = nil
            }
            // Return to previous mode (likely reviewing since user scrolled up)
            mode = .reviewing

        case .appendNew:
            if mode == .following {
                scrollPosition.scrollTo(edge: .bottom)
            } else {
                hasUnreadContent = true
            }

        case .updateExisting:
            // Streaming content - only scroll if following
            if mode == .following {
                scrollPosition.scrollTo(edge: .bottom)
            }

        case .initialLoad:
            // defaultScrollAnchor(.bottom) handles initial positioning
            break
        }
    }

    // MARK: - User Actions

    /// Call when user sends a new message
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
        withAnimation(Animation.tronStandard) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// Scroll to a deep link target (tool call or event).
    /// Sets mode to reviewing to prevent auto-scroll from interfering.
    /// - Parameters:
    ///   - messageId: The UUID of the message to scroll to
    ///   - proxy: Optional ScrollViewProxy for proxy-based scrolling
    func scrollToDeepLinkTarget(messageId: UUID, using proxy: ScrollViewProxy?) {
        // Set mode to reviewing (user initiated navigation, not auto-follow)
        mode = .reviewing
        hasUnreadContent = false
        graceUntil = Date().addingTimeInterval(gracePeriod)

        // Scroll with animation, centering the target message
        withAnimation(.tronStandard) {
            proxy?.scrollTo(messageId, anchor: .center)
        }
    }

    /// Call from scroll position tracking
    /// - Parameters:
    ///   - distanceFromBottom: Negative when above bottom, positive when at/below bottom
    ///   - isProcessing: Whether agent is currently processing
    func userScrolled(distanceFromBottom: CGFloat, isProcessing: Bool) {
        // Skip during grace period
        guard Date() > graceUntil else { return }

        // Skip if in loading mode (prepending history)
        guard mode != .loading else { return }

        if distanceFromBottom < -atBottomThreshold && mode == .following {
            // User scrolled up from bottom
            mode = .reviewing
        } else if distanceFromBottom > -atBottomThreshold && !isProcessing && mode == .reviewing {
            // User scrolled back to bottom (only when not processing)
            mode = .following
            hasUnreadContent = false
        }
    }

    /// Call when processing ends
    func processingEnded() {
        if mode == .following {
            withAnimation(Animation.tronFast) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        hasUnreadContent = false
    }

    /// Call when bottom content (like connection pill) changes height
    /// Ensures smooth scroll adjustment when content at bottom shrinks/grows
    func bottomContentHeightChanged(using proxy: ScrollViewProxy?) {
        // Only adjust if we're following - reviewing mode maintains position
        if mode == .following {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                proxy?.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Query Methods

    /// Whether we should show the "New content" button
    var shouldShowScrollToBottomButton: Bool {
        mode == .reviewing && hasUnreadContent
    }

    /// Whether auto-scroll is enabled (for compatibility during transition)
    var autoScrollEnabled: Bool {
        mode == .following
    }

    /// Check if we should auto-scroll with debouncing
    /// Returns true only if in following mode AND debounce interval has passed
    /// Use this to prevent scroll jitter during rapid streaming updates
    func shouldAutoScrollWithDebounce() -> Bool {
        guard mode == .following else { return false }

        let now = CACurrentMediaTime()
        if now - lastScrollTime < scrollDebounceInterval {
            return false
        }
        lastScrollTime = now
        return true
    }
}
