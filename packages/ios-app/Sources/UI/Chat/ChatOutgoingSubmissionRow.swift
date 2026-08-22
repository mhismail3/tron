import SwiftUI
import UIKit

/// Shared behavior-aware visual core for queued-kind prompt lifecycles. The
/// surrounding shell owns whether facts are optimistic, pending, or
/// authoritative; this card never invents queue position or edit capability.
struct ChatPromptCard<AttachmentContent: View, StatusContent: View>: View {
    let behavior: ChatPromptBehavior
    let text: String
    let detail: String?
    let isInteractive: Bool
    let attachmentContent: AttachmentContent
    let statusContent: StatusContent

    init(
        behavior: ChatPromptBehavior,
        text: String,
        detail: String? = nil,
        isInteractive: Bool = false,
        @ViewBuilder attachmentContent: () -> AttachmentContent,
        @ViewBuilder statusContent: () -> StatusContent
    ) {
        self.behavior = behavior
        self.text = text
        self.detail = detail
        self.isInteractive = isInteractive
        self.attachmentContent = attachmentContent()
        self.statusContent = statusContent()
    }

    private var accent: Color {
        switch behavior {
        case .steer: return .tronEmerald
        case .followUp: return .tronPurple
        case .ordinary, .unknown: return .tronTextSecondary
        }
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: ChatPromptContainerStyle.cornerRadius,
            style: .continuous
        )
        VStack(alignment: .leading, spacing: QueuedMessageCardLayout.contentSpacing) {
            HStack(alignment: .center, spacing: 10) {
                Text(behavior.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Image(systemName: behavior == .steer
                    ? "arrow.turn.up.right"
                    : "text.line.last.and.arrowtriangle.forward")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(
                        width: QueuedMessageCardLayout.arrowContainerSize,
                        height: QueuedMessageCardLayout.arrowContainerSize
                    )
                    .background(accent.opacity(0.13), in: Circle())
                statusContent
            }

            if !text.isEmpty {
                UserPromptText(text: text)
            }
            attachmentContent
        }
        .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
        .padding(.top, QueuedMessageCardLayout.contentSpacing)
        .padding(.bottom, ChatPromptContainerStyle.queuedMessageBottomPadding)
        .contentShape(shape)
        .glassEffect(
            isInteractive
                ? .regular.tint(accent.opacity(ChatPromptContainerStyle.tintOpacity)).interactive()
                : .regular.tint(accent.opacity(ChatPromptContainerStyle.tintOpacity)),
            in: shape
        )
    }
}

/// An authoritative pending prompt reconstructed from the Gateway snapshot.
/// It stays in the user-message position while compaction or prompt preflight
/// delays the canonical transcript entry.
struct ChatPendingPromptRow: View, Equatable {
    let presentation: ChatPendingPromptPresentation

    var body: some View {
        if presentation.promptBehavior.isQueuedKind {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 24)
                queueCard
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(queueAccessibilityLabel)
        } else {
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
                        QueuedMessageAttachmentChipRow(chips: attachmentChips, accent: .tronTextSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.text.isEmpty ? presentation.statusTitle : "\(presentation.statusTitle): \(presentation.text)")
        }
    }

    private var queueAccessibilityLabel: String {
        let chips = QueuedMessageAttachmentPresentation.chips(
            attachmentCount: presentation.attachmentCount,
            photoCount: presentation.photoCount,
            fileAttachmentCount: presentation.fileAttachmentCount
        )
        let attachmentLabel = QueuedMessageAttachmentPresentation.accessibilityLabel(chips: chips)
        return [presentation.statusTitle, presentation.text.isEmpty ? nil : presentation.text, attachmentLabel.isEmpty ? nil : attachmentLabel]
            .compactMap { $0 }
            .joined(separator: ": ")
    }

    @ViewBuilder
    private var queueCard: some View {
        let chips = QueuedMessageAttachmentPresentation.chips(
            attachmentCount: presentation.attachmentCount,
            photoCount: presentation.photoCount,
            fileAttachmentCount: presentation.fileAttachmentCount
        )
        ChatPromptCard(
            behavior: presentation.promptBehavior,
            text: presentation.text,
            detail: presentation.isCompacting ? "After compaction" : "Sending",
            attachmentContent: {
                if !chips.isEmpty {
                    QueuedMessageAttachmentChipRow(
                        chips: chips,
                        accent: presentation.promptBehavior == .followUp ? .tronPurple : .tronEmerald
                    )
                }
            },
            statusContent: { EmptyView() }
        )
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
        if presentation.promptBehavior.isQueuedKind {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 24)
                ChatPromptCard(
                    behavior: presentation.promptBehavior,
                    text: presentation.text,
                    detail: "Sending",
                    attachmentContent: { queuedAttachmentChips },
                    statusContent: { EmptyView() }
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(promptAccessibilityLabel)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 4) {
                    attachmentStrip
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
    }

    private var promptAccessibilityLabel: String {
        let chips = QueuedMessageAttachmentPresentation.chips(for: attachments)
        let attachmentLabel = QueuedMessageAttachmentPresentation.accessibilityLabel(chips: chips)
        return [
            presentation.statusTitle,
            presentation.text.isEmpty ? nil : presentation.text,
            attachmentLabel.isEmpty ? nil : attachmentLabel,
        ]
        .compactMap { $0 }
        .joined(separator: ": ")
    }

    @ViewBuilder
    private var queuedAttachmentChips: some View {
        let chips = QueuedMessageAttachmentPresentation.chips(for: attachments)
        if !chips.isEmpty {
            QueuedMessageAttachmentChipRow(
                chips: chips,
                accent: presentation.promptBehavior == .followUp ? .tronPurple : .tronEmerald
            )
        }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        AttachmentThumbnailSurface(
                            image: attachment.preparedThumbnail.map { UIImage(cgImage: $0.image) },
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
    }

    private var accessibilityLabel: String {
        [presentation.statusTitle, presentation.text.isEmpty ? "Prompt attachments" : presentation.text]
            .compactMap { $0 }
            .joined(separator: ": ")
    }
}
