import SwiftUI
import UIKit

/// A presentation-only user bubble shown until the authoritative transcript or
/// queue projection owns the submission. It intentionally uses the same visual
/// language as a canonical user message: no transport-status label or duplicate
/// "submitted" affordance is shown.
struct ChatOutgoingSubmissionRow: View, Equatable {
    let presentation: ChatOutgoingSubmissionPresentation
    let attachments: [PendingAttachment]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentation == rhs.presentation && lhs.attachments == rhs.attachments
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 4) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                if attachment.mimeType.hasPrefix("image/"),
                                   let data = attachment.previewData,
                                   let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .glassEffect(
                                            .regular.tint(Color.tronBlue.opacity(0.18)),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        )
                                        .accessibilityLabel("Image attachment")
                                } else {
                                    TranscriptFileChip(name: attachment.name, mimeType: attachment.mimeType, size: attachment.size)
                                }
                            }
                        }
                    }
                    .scrollClipDisabled()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.vertical, 3)
                    .accessibilityLabel("Prompt attachments")
                }
                if !presentation.text.isEmpty {
                    UserPromptText(text: presentation.text)
                        .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                        .padding(.top, ChatPromptContainerStyle.topPadding)
                        .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                        .modifier(UserPromptGlassModifier())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.text.isEmpty ? "Prompt attachments" : presentation.text)
    }
}
