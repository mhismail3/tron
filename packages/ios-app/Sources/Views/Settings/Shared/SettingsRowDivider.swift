import SwiftUI

/// Standard divider between rows in a settings card.
/// Indented to align with text content after the 18px icon frame.
struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 38)
    }
}
