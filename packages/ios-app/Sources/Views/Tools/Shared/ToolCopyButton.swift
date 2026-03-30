import SwiftUI

// MARK: - Copy Button

/// Tiny reusable copy button (icon-only) for section headers.
/// Replaces the duplicated copy button pattern across all tool detail sheets.
@available(iOS 26.0, *)
struct ToolCopyButton: View {
    let content: String
    let accent: Color

    var body: some View {
        Button {
            UIPasteboard.general.string = content
        } label: {
            Image(systemName: "doc.on.doc")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(accent.opacity(0.6))
        }
    }
}
