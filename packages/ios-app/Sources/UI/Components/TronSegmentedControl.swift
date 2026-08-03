import SwiftUI

/// Equal-width liquid-glass tabs used by dashboard and detail sheets.
///
/// The control owns the selected/unselected treatment so feature sheets do not
/// recreate solid tab bars with subtly different spacing or contrast.
struct TronSegmentedControl<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var accent: Color = .tronEmerald
    var animatesSelection: Bool = true
    @Environment(\.usesLiquidGlassForControls) private var usesLiquidGlass

    var body: some View {
        Group {
            if usesLiquidGlass {
                GlassEffectContainer(spacing: 4) {
                    optionsView(usesLiquidGlass: true)
                }
            } else {
                optionsView(usesLiquidGlass: false)
            }
        }
    }

    private func optionsView(usesLiquidGlass: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection == option.value
                Button {
                    select(option.value)
                } label: {
                    Text(option.label)
                        .font(
                            TronTypography.sans(
                                size: TronTypography.sizeBody3,
                                weight: isSelected ? .semibold : .medium
                            )
                        )
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(
                    TronGlassSelectionButtonStyle(
                        isSelected: isSelected,
                        accent: accent,
                        shape: .roundedRectangle(radius: 8),
                        usesLiquidGlass: usesLiquidGlass
                    )
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func select(_ value: T) {
        guard selection != value else { return }
        if animatesSelection {
            withAnimation(.easeOut(duration: 0.12)) {
                selection = value
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                selection = value
            }
        }
    }
}
