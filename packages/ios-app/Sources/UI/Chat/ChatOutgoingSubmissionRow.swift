import SwiftUI
import UIKit

/// An authoritative pending prompt reconstructed from the Gateway snapshot.
/// It stays in the user-message position while compaction or prompt preflight
/// delays the canonical transcript entry.
struct ChatPendingPromptRow: View, Equatable {
    let presentation: ChatPendingPromptPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 4) {
                Label(presentation.statusTitle, systemImage: "clock.arrow.circlepath")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextSecondary)
                    .accessibilityLabel(presentation.statusTitle)
                if !presentation.text.isEmpty {
                    UserPromptText(text: presentation.text)
                        .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                        .padding(.top, ChatPromptContainerStyle.topPadding)
                        .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                        .modifier(UserPromptGlassModifier())
                }
                let attachmentChips = QueuedMessageAttachmentPresentation.chips(
                    attachmentCount: presentation.attachmentCount,
                    photoCount: presentation.photoCount,
                    fileAttachmentCount: presentation.fileAttachmentCount
                )
                if !attachmentChips.isEmpty {
                    QueuedMessageAttachmentChipRow(
                        chips: attachmentChips,
                        accent: presentation.behavior == .followUp ? .tronPurple : .tronEmerald
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.text.isEmpty ? presentation.statusTitle : "\(presentation.statusTitle): \(presentation.text)")
    }
}

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
                                AttachmentThumbnailSurface(
                                    image: attachment.previewData.flatMap(UIImage.init(data:)),
                                    name: attachment.name,
                                    mimeType: attachment.mimeType
                                )
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Attachment \(attachment.name)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .scrollClipDisabled()
                    .defaultScrollAnchor(.trailing)
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
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [presentation.statusTitle, presentation.text.isEmpty ? "Prompt attachments" : presentation.text]
            .compactMap { $0 }
            .joined(separator: ": ")
    }
}
