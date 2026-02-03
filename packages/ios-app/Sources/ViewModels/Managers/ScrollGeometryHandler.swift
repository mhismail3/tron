import Foundation

// MARK: - Scroll State

/// Tracks scroll state for detecting user scroll vs content growth
/// Used to distinguish intentional user scrolling from layout changes
public struct ScrollState: Equatable {
    /// Whether the scroll position is near the bottom of content
    public let isNearBottom: Bool
    /// Current scroll offset (y position)
    public let offset: CGFloat
    /// Total content height - used to detect content growth
    public let contentHeight: CGFloat

    public init(isNearBottom: Bool, offset: CGFloat, contentHeight: CGFloat) {
        self.isNearBottom = isNearBottom
        self.offset = offset
        self.contentHeight = contentHeight
    }
}

// MARK: - Scroll Geometry Decision

/// Decision from processing scroll geometry changes
/// Determines what action the scroll handler should take
public enum ScrollGeometryDecision: Equatable {
    /// Don't call userDidScroll - no action needed
    case noChange
    /// User actively scrolled up → switch to reviewing mode
    case scrolledUp
    /// Update based on isNearBottom status
    case updateNearBottom(Bool)
}

// MARK: - Scroll Geometry Handler

/// Pure function to determine scroll behavior from geometry changes
/// Extracted for testability - distinguishes user scroll from content growth
public enum ScrollGeometryHandler {

    /// Threshold for detecting intentional user scroll (in points)
    private static let scrollThreshold: CGFloat = 5

    /// Process a scroll geometry change and determine what action to take
    ///
    /// In following mode, only switches to reviewing if user actively scrolled up.
    /// This prevents the "New Content" button from appearing incorrectly when
    /// content grows (model switch, thinking blocks, etc.) before auto-scroll catches up.
    ///
    /// - Parameters:
    ///   - oldState: Previous scroll state
    ///   - newState: New scroll state
    ///   - isFollowingMode: Whether coordinator is in following mode (auto-scroll enabled)
    ///   - isCascading: Whether initial cascade animation is running
    /// - Returns: Decision on what scroll action to take
    public static func processGeometryChange(
        oldState: ScrollState,
        newState: ScrollState,
        isFollowingMode: Bool,
        isCascading: Bool
    ) -> ScrollGeometryDecision {
        // Don't process during cascade animation - all changes are expected
        guard !isCascading else { return .noChange }

        // Detect user actively scrolling up: offset DECREASES by more than threshold
        // This is the only reliable indicator of intentional upward scroll
        let userScrolledUp = newState.offset < oldState.offset - scrollThreshold

        if userScrolledUp {
            // User intentionally scrolled up - always switch to reviewing mode
            return .scrolledUp
        }

        // KEY FIX: In following mode, only switch to reviewing if user actively scrolled up.
        // Any other reason for isNearBottom=false should NOT trigger mode switch:
        // - Content growth (layout hasn't caught up yet)
        // - Model switch notifications
        // - Thinking blocks appearing
        // - Tool results expanding
        // - Any layout adjustment
        // The auto-scroll handlers will scroll to bottom; don't preemptively switch modes.
        if isFollowingMode && !newState.isNearBottom {
            return .noChange
        }

        // Normal case: update based on near-bottom status
        // This handles reviewing mode (staying in it or switching to following when at bottom)
        return .updateNearBottom(newState.isNearBottom)
    }
}
