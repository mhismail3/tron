import SwiftUI

/// Row showing a snippet's name and a single-line text preview.
@available(iOS 26.0, *)
struct PromptSnippetRow: View {
    let snippet: PromptSnippet

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snippet.name)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
            Text(snippet.text)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Snippet \(snippet.name)")
    }
}
