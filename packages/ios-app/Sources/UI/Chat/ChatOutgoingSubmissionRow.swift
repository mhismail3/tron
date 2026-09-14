import SwiftUI
import UIKit

/// Capture exactly the displayed input, not a later template or row update.
struct ChatMessageActionSelection: Identifiable {
    let id = UUID()
    let text: String
}

/// App-authored popover contents cannot acquire system context-menu Siri actions.
struct ChatMessageActionsPopover<Actions: View>: ViewModifier {
    let text: String
    var hasAdditionalActions = false
    @ViewBuilder var additionalActions: () -> Actions
    @State private var selection: ChatMessageActionSelection?
    #if HOSTED_TEST
    @Environment(\.chatMessageActionsProbe) private var probe
    #endif

    private var canPresent: Bool { !text.isEmpty || hasAdditionalActions }

    private func present() {
        guard canPresent else { return }
        selection = .init(text: text)
    }

    func body(content: Content) -> some View {
        content
            // Keep the UILabel hit region on the bubble, not the full-width row.
            .contentShape(.interaction, RoundedRectangle(cornerRadius: ChatPromptContainerStyle.cornerRadius))
            .onLongPressGesture(perform: present)
            .accessibilityActions {
                if canPresent {
                    Button("Message actions", action: present)
                }
            }
            .popover(item: $selection) { selected in
                ChatMessageActionsContent(text: selected.text, additionalActions: additionalActions)
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: canPresent) { _, available in
                if !available { selection = nil }
            }
            .onDisappear { selection = nil }
            #if HOSTED_TEST
            .onAppear { probe?.open = present }
            .onDisappear { probe?.open = nil }
            #endif
    }
}

extension ChatMessageActionsPopover where Actions == EmptyView {
    init(text: String) {
        self.text = text
        additionalActions = { EmptyView() }
    }
}

struct ChatMessageActionsContent<Actions: View>: View {
    let text: String
    @ViewBuilder var additionalActions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !text.isEmpty {
                ChatMessagePopoverAction(title: "Copy", icon: "doc.on.doc") {
                    UIPasteboard.general.string = text
                }
            }
            additionalActions()
        }
        .padding(8)
        .frame(minWidth: 180)
    }
}

struct ChatMessagePopoverAction: View {
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    #if HOSTED_TEST
    @Environment(\.chatMessageActionsProbe) private var probe
    #endif

    private func perform() {
        dismiss()
        action()
    }

    var body: some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: icon)
                .font(TronTypography.body)
                .foregroundStyle(role == .destructive ? Color.tronError : .tronTextPrimary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if HOSTED_TEST
        .onAppear { probe?.actions[title] = perform }
        .onDisappear { probe?.actions[title] = nil }
        #endif
    }
}

#if HOSTED_TEST
@MainActor
final class ChatMessageActionsProbe {
    var open: (() -> Void)?
    var actions: [String: () -> Void] = [:]
}

private struct ChatMessageActionsProbeKey: EnvironmentKey {
    static let defaultValue: ChatMessageActionsProbe? = nil
}

extension EnvironmentValues {
    var chatMessageActionsProbe: ChatMessageActionsProbe? {
        get { self[ChatMessageActionsProbeKey.self] }
        set { self[ChatMessageActionsProbeKey.self] = newValue }
    }
}
#endif

/// Shared behavior-aware visual core for queued-kind prompt lifecycles. The
/// surrounding shell owns whether facts are optimistic, pending, or
/// authoritative; this card never invents queue position or edit capability.
struct ChatPromptCard<AttachmentContent: View, StatusContent: View>: View {
    let behavior: ChatPromptBehavior
    let title: String
    let text: String
    let detail: String?
    let isInteractive: Bool
    let onActivate: (() -> Void)?
    let attachmentContent: AttachmentContent
    let statusContent: StatusContent

    init(
        behavior: ChatPromptBehavior,
        title: String? = nil,
        text: String,
        detail: String? = nil,
        isInteractive: Bool = false,
        onActivate: (() -> Void)? = nil,
        @ViewBuilder attachmentContent: () -> AttachmentContent,
        @ViewBuilder statusContent: () -> StatusContent
    ) {
        self.behavior = behavior
        self.title = title ?? behavior.title
        self.text = text
        self.detail = detail
        self.isInteractive = isInteractive
        self.onActivate = onActivate
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
        BoundedTrailingContentLayout(maxWidth: UserPromptTextLayoutPolicy.maximumWidth) {
            VStack(alignment: .leading, spacing: QueuedMessageCardLayout.contentSpacing) {
                promptContent
                attachmentContent
            }
            .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
            .padding(.top, QueuedMessageCardLayout.contentSpacing)
            .padding(.bottom, ChatPromptContainerStyle.queuedMessageBottomPadding)
            .contentShape(shape)
            // The whole prompt surface is the editor affordance, not only its
            // title/text. Attachment controls still retain their own actions.
            .modifier(ChatPromptActivationModifier(action: onActivate))
            .glassEffect(
                isInteractive
                    ? .regular.tint(accent.opacity(ChatPromptContainerStyle.tintOpacity)).interactive()
                    : .regular.tint(accent.opacity(ChatPromptContainerStyle.tintOpacity)),
                in: shape
            )
        }
    }

    private var promptContent: some View {
        VStack(alignment: .leading, spacing: QueuedMessageCardLayout.contentSpacing) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
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
        }
    }
}

private struct ChatPromptActivationModifier: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content
                .onTapGesture(perform: action)
                .accessibilityHint("Opens the queued message editor")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}

/// An authoritative pending prompt reconstructed from the Gateway snapshot.
/// It stays in the user-message position while compaction or prompt preflight
/// delays the canonical transcript entry.
struct ChatPendingPromptRow: View, Equatable {
    let presentation: ChatPendingPromptPresentation

    private var displayText: String {
        UserPromptPresentationPolicy.promptDisplayText(presentation.resourceInvocation) ?? presentation.text
    }

    var body: some View {
        if presentation.usesQueuedCardVisual {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 24)
                queueCard
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(queueAccessibilityLabel)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 4) {
                    if let resource = presentation.resourceInvocation, !resource.isExtensionCommand {
                        CanonicalResourceChip(resource: resource)
                    }
                    Label(presentation.statusTitle, systemImage: "clock.arrow.circlepath")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                        .accessibilityLabel(presentation.statusTitle)
                    if !displayText.isEmpty {
                        UserPromptText(text: displayText)
                            .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                            .padding(.top, ChatPromptContainerStyle.topPadding)
                            .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                            .modifier(UserPromptGlassModifier())
                            .modifier(ChatMessageActionsPopover(text: displayText))
                    }
                    let attachmentChips = QueuedMessageAttachmentPresentation.chips(
                        attachmentCount: presentation.attachmentCount,
                        photoCount: presentation.photoCount,
                        fileAttachmentCount: presentation.fileAttachmentCount,
                        attachments: presentation.attachments
                    )
                    if !attachmentChips.isEmpty {
                        QueuedMessageAttachmentChipRow(chips: attachmentChips, accent: .tronTextSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(displayText.isEmpty ? presentation.statusTitle : "\(presentation.statusTitle): \(displayText)")
        }
    }

    private var queueAccessibilityLabel: String {
        let chips = QueuedMessageAttachmentPresentation.chips(
            attachmentCount: presentation.attachmentCount,
            photoCount: presentation.photoCount,
            fileAttachmentCount: presentation.fileAttachmentCount,
            attachments: presentation.attachments
        )
        let attachmentLabel = QueuedMessageAttachmentPresentation.accessibilityLabel(chips: chips)
        return [presentation.statusTitle, displayText.isEmpty ? nil : displayText, attachmentLabel.isEmpty ? nil : attachmentLabel]
            .compactMap { $0 }
            .joined(separator: ": ")
    }

    @ViewBuilder
    private var queueCard: some View {
        let chips = QueuedMessageAttachmentPresentation.chips(
            attachmentCount: presentation.attachmentCount,
            photoCount: presentation.photoCount,
            fileAttachmentCount: presentation.fileAttachmentCount,
            attachments: presentation.attachments
        )
        VStack(alignment: .trailing, spacing: 4) {
            if let resource = presentation.resourceInvocation, !resource.isExtensionCommand {
                CanonicalResourceChip(resource: resource)
            }
            ChatPromptCard(
                behavior: presentation.cardBehavior,
                title: presentation.cardTitle,
                text: displayText,
                detail: presentation.cardDetail,
                attachmentContent: {
                    if !chips.isEmpty {
                        QueuedMessageAttachmentChipRow(
                            chips: chips,
                            accent: presentation.cardBehavior == .followUp ? .tronPurple : .tronEmerald
                        )
                    }
                },
                statusContent: { EmptyView() }
            )
            .modifier(ChatMessageActionsPopover(text: displayText))
        }
    }
}

/// A presentation-only user bubble shown until the authoritative transcript or
/// queue projection owns the submission. It intentionally uses the same visual
/// language as a canonical user message: no transport-status label or duplicate
/// "submitted" affordance is shown.
struct ChatOutgoingSubmissionRow: View, Equatable {
    let presentation: ChatOutgoingSubmissionPresentation
    let attachments: [PendingAttachment]

    private var displayText: String {
        UserPromptPresentationPolicy.promptDisplayText(presentation.resourceInvocation) ?? presentation.text
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentation == rhs.presentation && lhs.attachments == rhs.attachments
    }

    var body: some View {
        if presentation.usesQueuedCardVisual {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 4) {
                    resourceChip
                    ChatPromptCard(
                        behavior: presentation.cardBehavior,
                        title: presentation.cardTitle,
                        text: displayText,
                        detail: presentation.cardDetail,
                        attachmentContent: { queuedAttachmentChips },
                        statusContent: { EmptyView() }
                    )
                    .modifier(ChatMessageActionsPopover(text: displayText))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(promptAccessibilityLabel)
        } else {
            // Match the canonical user row's full-width proposal exactly. An
            // extra leading spacer narrows long optimistic prompts, then lets
            // them rewrap and change height when canonical content replaces
            // the same physical row.
            VStack(alignment: .trailing, spacing: 4) {
                resourceChip
                attachmentStrip
                if !displayText.isEmpty {
                    UserPromptText(text: displayText)
                        .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                        .padding(.top, ChatPromptContainerStyle.topPadding)
                        .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                        .modifier(UserPromptGlassModifier())
                        .modifier(ChatMessageActionsPopover(text: displayText))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var promptAccessibilityLabel: String {
        let chips = QueuedMessageAttachmentPresentation.chips(for: attachments)
        let attachmentLabel = QueuedMessageAttachmentPresentation.accessibilityLabel(chips: chips)
        return [
            presentation.statusTitle,
            resourceAccessibilityLabel,
            displayText.isEmpty ? nil : displayText,
            attachmentLabel.isEmpty ? nil : attachmentLabel,
        ]
        .compactMap { $0 }
        .joined(separator: ": ")
    }

    @ViewBuilder
    private var resourceChip: some View {
        if let resource = presentation.resourceInvocation, !resource.isExtensionCommand {
            CanonicalResourceChip(resource: resource)
        }
    }

    @ViewBuilder
    private var queuedAttachmentChips: some View {
        let chips = QueuedMessageAttachmentPresentation.chips(for: attachments)
        if !chips.isEmpty {
            QueuedMessageAttachmentChipRow(
                chips: chips,
                accent: presentation.cardBehavior == .followUp ? .tronPurple : .tronEmerald
            )
        }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        if attachment.mimeType.lowercased().hasPrefix("image/") {
                            AttachmentThumbnailSurface(
                                image: attachment.preparedThumbnail.map { UIImage(cgImage: $0.image) },
                                name: attachment.name,
                                mimeType: attachment.mimeType
                            )
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Attachment \(attachment.name)")
                        } else if let blobID = attachment.transportBlobID {
                            TranscriptFileChip(
                                name: attachment.name,
                                mimeType: attachment.mimeType,
                                size: attachment.size,
                                blobID: blobID
                            )
                        }
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

    private var resourceAccessibilityLabel: String? {
        guard let resource = presentation.resourceInvocation,
              !resource.isExtensionCommand else { return nil }
        return "\(CanonicalResourceChipPresentation.kindTitle(for: resource)) \(CanonicalResourceChipPresentation.title(for: resource))"
    }

    private var accessibilityLabel: String {
        [
            presentation.statusTitle,
            resourceAccessibilityLabel,
            displayText.isEmpty
                ? (attachments.isEmpty ? nil : "Prompt attachments")
                : displayText,
        ]
        .compactMap { $0 }
        .joined(separator: ": ")
    }
}
