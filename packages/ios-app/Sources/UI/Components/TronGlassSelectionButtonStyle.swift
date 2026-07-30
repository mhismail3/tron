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
    var usesLiquidGlass = true

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        switch shape {
        case .capsule:
            if usesLiquidGlass {
                styled(configuration)
                    .glassEffect(
                        .regular
                            .tint(accent.opacity(isSelected ? 0.28 : 0.08))
                            .interactive(),
                        in: .capsule
                    )
            } else {
                staticStyled(configuration, shape: Capsule())
            }
        case let .roundedRectangle(radius):
            if usesLiquidGlass {
                styled(configuration)
                    .glassEffect(
                        .regular
                            .tint(accent.opacity(isSelected ? 0.28 : 0.08))
                            .interactive(),
                        in: .rect(cornerRadius: radius)
                    )
            } else {
                staticStyled(
                    configuration,
                    shape: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
            }
        }
    }

    private func styled(_ configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(accent)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private func staticStyled<S: InsettableShape>(
        _ configuration: Configuration,
        shape: S
    ) -> some View {
        styled(configuration)
            .background {
                shape.fill(accent.opacity(isSelected ? 0.16 : 0.05))
            }
            .overlay {
                shape.stroke(accent.opacity(isSelected ? 0.24 : 0.1), lineWidth: 0.5)
            }
    }
}
