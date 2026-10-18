import SwiftUI

/// Both branches use the shared surface owners; content geometry never changes.
struct ContextMessageSurface: ViewModifier {
    let accent: Color
    let isLong: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isLong {
            content.tronScrollSurface(accent: accent, tintOpacity: 0.08)
        } else {
            content.tronGlassSurface(accent: accent, tintOpacity: 0.08)
        }
    }
}
