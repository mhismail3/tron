import Foundation

/// Unified duration formatting from milliseconds.
/// Replaces duplicate formatting logic in ToolDetailComponents, ToolResultViews,
/// AutomationDetailSheet, and AutomationRunDetailSheet.
enum DurationFormatter {

    enum Style {
        /// Shows minutes breakdown for durations >= 60s: "2m 5s"
        case full
        /// Always uses decimal seconds, no minutes: "125.0s"
        case compact
    }

    static func format(_ ms: Int, style: Style = .full) -> String {
        if ms < 1000 { return "\(ms)ms" }
        if style == .compact || ms < 60000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        let minutes = ms / 60000
        let seconds = (ms % 60000) / 1000
        return "\(minutes)m \(seconds)s"
    }
}
