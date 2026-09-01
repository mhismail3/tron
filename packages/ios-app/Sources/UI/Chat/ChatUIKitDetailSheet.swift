import SwiftUI

/// Route-only detail presentation for native transcript intents. The route is
/// owned by ChatView; UIKit supplies only the selected immutable presentation.
struct ChatUIKitDetailSheet: View {
    let route: ChatUIKitDetailRoute
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder var body: some View {
        switch route.kind {
        case .attachment(let attachment):
            ChatUIKitAttachmentDetailSheet(route: attachment)
        case .toolRun(let run, let tools):
            ToolRunDetailSheet(run: run, tools: tools)
        default:
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
    }

    @ViewBuilder
    private var content: some View {
        switch route.kind {
        case .attachment:
            EmptyView()
        case .toolRun:
            EmptyView()
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

private struct ChatUIKitAttachmentDetailSheet: View {
    let route: ChatUIKitAttachmentDetailRoute
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    private var attachment: ChatUIKitTranscriptAttachment { route.attachment }
    private var identity: ChatMediaIdentity? {
        attachment.blobID.flatMap { model.chatMediaIdentity(blobID: $0) }
    }

    @ViewBuilder var body: some View {
        if attachment.mimeType.hasPrefix("image/"),
           let initial = image ?? attachment.preparedThumbnail {
            AttachmentImagePreviewSheet(image: initial, title: attachment.name)
                .task(id: route.id) {
                    guard let identity,
                          let full = try? await model.chatMedia.fullPreview(
                              for: identity,
                              leaseID: route.id
                          ), !Task.isCancelled else { return }
                    image = full
                }
                .onDisappear {
                    if let identity {
                        model.chatMedia.cancelFullPreview(for: identity, leaseID: route.id)
                    }
                }
        } else {
            AttachmentFilePreviewSheet(
                name: attachment.name,
                mimeType: attachment.mimeType,
                source: identity.map {
                    .remote(identity: $0, leaseID: route.id)
                } ?? .unavailable
            )
        }
    }
}
