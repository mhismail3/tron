import SwiftUI

// MARK: - Copy Button

/// Pill-shaped copy button with animated "Copied" feedback for section headers.
/// Used across all tool detail sheets for section-level copy actions.
@available(iOS 26.0, *)
struct CapabilityCopyButton: View {
    let content: String
    let accent: Color
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = content
            withAnimation(.easeInOut(duration: 0.2)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                if copied {
                    Text("Copied")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                }
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(accent.opacity(copied ? 0.9 : 0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(accent.opacity(copied ? 0.15 : 0.08))
            }
            .contentShape(Capsule())
        }
    }
}
