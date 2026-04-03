import SwiftUI

/// State for the pull-up panel gesture on the input area.
/// Two discrete positions: collapsed (default) and expanded (panel revealed).
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

    // MARK: - Constants

    /// Height of the revealed panel content area.
    static let expandedHeight: CGFloat = 320

    /// Minimum visual offset (after rubber-banding) to trigger a snap.
    static let dragThreshold: CGFloat = 60

    /// Minimum velocity (pt/s) to trigger a snap even with small distance.
    static let velocityThreshold: CGFloat = 300

    /// Rubber-band resistance factor. Lower = more resistance.
    static let rubberBandFactor: CGFloat = 0.4
}
