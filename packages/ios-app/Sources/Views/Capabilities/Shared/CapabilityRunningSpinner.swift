import SwiftUI

// MARK: - Running Spinner

/// Shared spinner for tool detail sheets in "running" state.
/// Eliminates the duplicated ProgressView + label pattern across 10 tool sheets.
@available(iOS 26.0, *)
struct CapabilityRunningSpinner: View {
    let title: String
    let accent: Color
    let tint: TintedColors
    let actionText: String

    var body: some View {
        CapabilityDetailSection(title: title, accent: accent, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(accent)
                    .scaleEffect(1.1)
                Text(actionText)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}
