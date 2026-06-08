import SwiftUI

extension View {
    /// Standard accessibility configuration for tappable chip views.
    func chipAccessibility(capability: String, status: String, summary: String = "") -> some View {
        let label = summary.isEmpty ? "\(capability), \(status)" : "\(capability), \(status), \(summary)"
        return self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("Opens detail sheet")
            .accessibilityAddTraits(.isButton)
    }
}
