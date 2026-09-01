import SwiftUI

/// Route-only detail presentation for native transcript intents. The route is
/// owned by ChatView; UIKit supplies only the selected immutable presentation.
struct ChatUIKitDetailSheet: View {
    let route: ChatUIKitDetailRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.tronBackground)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.tronEmerald)
                        }
                        .accessibilityLabel("Done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }

    @ViewBuilder
    private var content: some View {
        switch route.kind {
        case .attachment(let attachment):
            if attachment.mimeType.hasPrefix("image/"), let image = attachment.preparedThumbnail {
                AttachmentImagePreviewSheet(image: image, title: attachment.name)
            } else {
                AttachmentFilePreviewSheet(
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    source: .unavailable
                )
            }
        case .tool(let tool):
            ToolDetailSheet(tool: tool, density: .expanded)
        case .thinking(let thinking):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let label = thinking.label, !label.isEmpty {
                        Text(label).font(TronTypography.sheetSectionHeader)
                    }
                    Text(thinking.segments.map(\.text).joined(separator: "\n"))
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        case .notification(let notification):
            VStack(alignment: .leading, spacing: 12) {
                Text(notification.title)
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextPrimary)
                if let detail = notification.detail {
                    Text(detail).foregroundStyle(Color.tronTextSecondary)
                }
                if let body = notification.body {
                    Text(body).foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
