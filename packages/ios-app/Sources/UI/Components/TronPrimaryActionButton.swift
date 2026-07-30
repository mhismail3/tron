import SwiftUI

/// Full-width liquid-glass action used to start typed worker work.
///
/// Keeping this treatment shared prevents each worker experience from falling
/// back to an opaque, feature-owned launch button.
struct TronPrimaryActionButton: View {
    let title: String
    let systemImage: String
    var accent: Color = .tronEmerald
    var isBusy = false
    var isEnabled = true
    let action: () -> Void
    @Environment(\.usesLiquidGlassForControls) private var usesLiquidGlass

    var body: some View {
        Button(action: action) {
            if usesLiquidGlass {
                label
                    .glassEffect(
                        .regular.tint(accent.opacity(isEnabled ? 0.24 : 0.08)).interactive(),
                        in: .capsule
                    )
            } else {
                label
                    .background {
                        Capsule()
                            .fill(accent.opacity(isEnabled ? 0.12 : 0.05))
                    }
                    .overlay {
                        Capsule()
                            .stroke(accent.opacity(isEnabled ? 0.22 : 0.1), lineWidth: 0.5)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var label: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
        .foregroundStyle(isEnabled ? accent : .tronTextMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .contentShape(Capsule())
    }
}
