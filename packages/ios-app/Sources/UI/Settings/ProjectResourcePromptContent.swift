import SwiftUI

/// Project Resources keeps the complete admitted template body, like prompt
/// details in Commands. Only the Gateway's explicit transport bound truncates it.
struct ProjectResourcePromptContent: View {
    let detail: CommandResourceDetail

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            if detail.contentTruncated == true {
                TronInfoCard(
                    icon: "text.badge.ellipsis",
                    text: "This prompt exceeds the content limit. Showing the first \(CommandResourceDetailPolicy.maximumContentBytes.formatted()) bytes; the complete template remains in its source file on the Mac.",
                    accent: .tronCyan
                )
            }
            if let content = detail.content, !content.isEmpty {
                TronMarkdownView(text: content, streaming: false)
            } else {
                Text("This prompt has no body content.")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
