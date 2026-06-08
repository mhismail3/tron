import SwiftUI

// MARK: - Empty State

/// Reusable empty/no-results state view (icon + message + optional subtitle).
/// Replaces the duplicated empty state pattern across 7 capability detail sheets.
struct CapabilityEmptyState: View {
    let title: String
    let icon: String
    let message: String
    let accent: Color
    let tint: TintedColors
    var subtitle: String? = nil

    var body: some View {
        CapabilityDetailSection(title: title, accent: accent, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: 28))
                    .foregroundStyle(tint.subtle)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
                if let subtitle {
                    Text(subtitle)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.subtle.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}
