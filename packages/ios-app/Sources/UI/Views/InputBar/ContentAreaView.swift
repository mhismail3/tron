import SwiftUI

// MARK: - Content Area View

enum ContentAreaChipItem: Identifiable, Equatable {
    case attachment(Attachment)

    var id: String {
        switch self {
        case .attachment(let attachment):
            return "attachment:\(attachment.id.uuidString)"
        }
    }

    static func items(attachments: [Attachment]) -> [ContentAreaChipItem] {
        attachments.map(ContentAreaChipItem.attachment)
    }
}

/// Main content area showing selected attachments with wrapping.
struct ContentAreaView: View {
    let attachments: [Attachment]
    let attachmentCapability: AttachmentCapability
    let onRemoveAttachment: (Attachment) -> Void

    var body: some View {
        WrappingHStack(spacing: 8, lineSpacing: 8) {
            ForEach(ContentAreaChipItem.items(attachments: attachments)) { item in
                switch item {
                case .attachment(let attachment):
                    AttachmentBubble(attachment: attachment, capability: attachmentCapability) {
                        onRemoveAttachment(attachment)
                    }
                    .transition(chipTransition)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: attachments.count)
    }

    private var chipTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.8).combined(with: .opacity),
            removal: .scale(scale: 0.6).combined(with: .opacity)
        )
    }
}
