import SwiftUI

/// A bounded, presentation-only acknowledgement row. It deliberately does
/// not reuse TranscriptRow: no synthetic TranscriptItem may look canonical.
struct ChatOutgoingSubmissionRow: View, Equatable {
    let presentation: ChatOutgoingSubmissionPresentation
    let attachments: [PendingAttachment]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentation == rhs.presentation && lhs.attachments == rhs.attachments
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 7) {
                if !presentation.text.isEmpty {
                    Text(presentation.text)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                if !attachments.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(attachments) { attachment in
                            Label(
                                attachment.name,
                                systemImage: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc"
                            )
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(1)
                        }
                    }
                }
                Label(
                    presentation.transportActive ? "Sending…" : "Submitted",
                    systemImage: presentation.transportActive ? "arrow.up.circle" : "checkmark.circle"
                )
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronEmerald)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.tronEmerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.tronEmerald.opacity(0.24), lineWidth: 0.75)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.transportActive ? "Sending message" : "Message submitted")
    }
}
