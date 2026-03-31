import SwiftUI

/// Glass card container for settings content.
/// Wraps content in a VStack with sectionFill background and rounded corners.
struct SettingsCard<Content: View>: View {
    var accent: Color = .tronEmerald
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .sectionFill(accent)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
