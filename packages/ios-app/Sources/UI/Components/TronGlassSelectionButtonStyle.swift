import SwiftUI

/// Shared liquid-glass treatment for compact, mutually exclusive choices.
///
/// Callers own label layout while this style owns selected contrast, material,
/// press feedback, and shape so tabs, appearance choices, and font choices do
/// not drift into separate solid-button visual languages.
struct TronGlassSelectionButtonStyle: ButtonStyle {
    enum Shape {
        case capsule
        case roundedRectangle(radius: CGFloat)
    }

    let isSelected: Bool
    var accent: Color = .tronEmerald
    var shape: Shape = .capsule

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        switch shape {
        case .capsule:
            styled(configuration)
                .glassEffect(
                    .regular
                        .tint(accent.opacity(isSelected ? 0.28 : 0.08))
                        .interactive(),
                    in: .capsule
                )
        case let .roundedRectangle(radius):
            styled(configuration)
                .glassEffect(
                    .regular
                        .tint(accent.opacity(isSelected ? 0.28 : 0.08))
                        .interactive(),
                    in: .rect(cornerRadius: radius)
                )
        }
    }

    private func styled(_ configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(accent)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

}
