import SwiftUI

extension View {
    /// Standard accessibility configuration for tappable chip views.
    func chipAccessibility(tool: String, status: String, summary: String = "") -> some View {
        let label = summary.isEmpty ? "\(tool), \(status)" : "\(tool), \(status), \(summary)"
        return self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("Opens detail sheet")
            .accessibilityAddTraits(.isButton)
    }
}
