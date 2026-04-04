import SwiftUI

/// State for the pull-up panel gesture on the input area.
/// Two discrete positions: collapsed (default) and expanded (suggestion row revealed).
@Observable
final class PullUpPanelState {
    enum Position {
        case collapsed
        case expanded
    }

    /// Current resting position of the panel.
    var position: Position = .collapsed

    /// Live drag offset applied during gesture (negative = upward pull).
    /// Reset to 0 when gesture ends.
    var dragOffset: CGFloat = 0

    var isExpanded: Bool { position == .expanded }

    /// Whether a long-press hold is active (input bar is "lifted").
    var isHoldActive: Bool = false

    /// Suggested follow-up prompts from LLM hook.
    var suggestions: [String] = []

    /// When true, pull-up drag gesture is disabled (agent is active).
    var isDragDisabled: Bool = false

    // MARK: - Constants

    /// Height of the revealed suggestion row.
    static let expandedHeight: CGFloat = 70

    /// Minimum visual offset (after rubber-banding) to trigger a snap.
    static let dragThreshold: CGFloat = 30

    /// Minimum velocity (pt/s) to trigger a snap even with small distance.
    static let velocityThreshold: CGFloat = 200

    /// Rubber-band resistance factor. Lower = more resistance.
    static let rubberBandFactor: CGFloat = 0.5
}
