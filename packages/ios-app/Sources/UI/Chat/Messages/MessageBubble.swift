import SwiftUI

// MARK: - Message Bubble (Terminal-style matching web UI)

struct MessageBubble: View {
    let message: ChatMessage
    var onTap: ((MessageBubbleTapAction) -> Void)?

    private var isUserMessage: Bool {
        message.role == .user
    }

    private var isAgentMessage: Bool {
        message.role == .agent && message.agentMessage != nil
    }

    private var agentMessageAccent: Color {
        guard let authority = message.agentMessage?.authority else {
            return .tronTextMuted
        }
        switch AgentMessagePresentation.accent(authority: authority) {
        case .operatorInstruction: return Color.tronAmber
        case .ownerInstruction: return Color.tronCyan
        case .peerMessage: return Color.tronPurple
        case .engineEvidence: return Color.tronEmerald
        case .unknown: return Color.tronTextMuted
        }
    }

    private var hasPreviewableImage: Bool {
        if message.attachments?.contains(where: \.isImage) == true {
            return true
        }
        switch message.content {
        case .images(let images):
            return !images.isEmpty
        case .attachments(let attachments):
            return attachments.contains(where: \.isImage)
        default:
            return false
        }
    }

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachedFileThumbnails(
                    attachments: attachments,
                    onPreview: { onTap?(.imagePreview($0)) }
                )
            }

            if !message.agentDeliveryProvenance.isEmpty {
                agentDeliveryProvenance
            }

            if let agentMessage = message.agentMessage {
                agentMessageProvenance(agentMessage)
            }

            if !message.isDeliveryProvenanceOnly {
                contentView
            }

            if let metadata = message.finalAssistantResponseMetadata {
                MessageMetadataBadge(metadata: metadata)
            }
        }
        .padding(.horizontal, isAgentMessage ? 12 : 0)
        .padding(.vertical, isAgentMessage ? 10 : 0)
        .background {
            if isAgentMessage {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(agentMessageAccent.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(agentMessageAccent.opacity(0.2), lineWidth: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
        .accessibilityElement(
            children: isUserMessage && !hasPreviewableImage ? .ignore : .contain
        )
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Content

    private var agentDeliveryProvenance: some View {
        Label(
            AgentDeliveryContinuationPresentation.label(message.agentDeliveryProvenance),
            systemImage: message.agentDeliveryProvenance.contains {
                $0.triggeredWake == true
            } ? "arrow.clockwise.circle.fill" : "tray.and.arrow.down.fill"
        )
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(.tronEmerald)
            .accessibilityHint(
                message.agentDeliveryProvenance.contains { $0.triggeredWake == true }
                    ? "The task resumed automatically from a durable update."
                    : "A durable update was included in this model turn."
            )
    }

    private func agentMessageProvenance(_ content: AgentMessageContent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: AgentMessagePresentation.symbol(kind: content.kind))
                    .foregroundStyle(agentMessageAccent)
                Text(AgentMessagePresentation.sender(content))
                    .font(TronTypography.sans(
                        size: TronTypography.sizeCaption,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                Text(AgentMessagePresentation.label(content.kind))
                    .font(TronTypography.pillValue)
                    .foregroundStyle(agentMessageAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(agentMessageAccent.opacity(0.12), in: Capsule())
                Spacer(minLength: 4)
                Text(AgentMessagePresentation.label(content.authority))
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronTextMuted)
            }
            if content.assignmentId != nil || content.replyTo != nil {
                HStack(spacing: 10) {
                    if let assignmentId = content.assignmentId {
                        Label(
                            String(assignmentId.prefix(18)),
                            systemImage: "checklist"
                        )
                    }
                    if content.replyTo != nil {
                        Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    }
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(AgentMessagePresentation.sender(content)), \(AgentMessagePresentation.label(content.kind)), \(AgentMessagePresentation.label(content.authority)) authority"
        )
    }

    private var accessibilityLabel: String {
        if let content = message.agentMessage {
            return "Agent message from \(AgentMessagePresentation.sender(content)), \(AgentMessagePresentation.label(content.kind)), \(AgentMessagePresentation.label(content.authority)): \(String(content.text.prefix(200)))"
        }
        return isUserMessage
            ? "You: \(String(message.content.textContent.prefix(200)))"
            : "Assistant message"
    }

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .text(let text):
            TextContentView(text: text, role: message.role)

        case .streaming(let text):
            StreamingContentView(text: text)

        case .thinking(let visible, let isExpanded, _, let kind):
            ThinkingContentView(
                content: visible,
                isExpanded: isExpanded
            ) {
                onTap?(.thinking(visible, kind: kind))
            }

        case .toolInvocation(let invocation):
            ToolInvocationChip(
                data: invocation,
                onTap: { onTap?(.toolInvocation(invocation)) },
                onCancel: { onTap?(.cancelToolInvocation(id: invocation.id)) }
            )

        case .toolResult(let result):
            ToolInvocationResultView(result: result)

        case .userInputRequest(let request):
            UserInputRequestChip(request: request) {
                onTap?(.userInput(request))
            }

        case .error(let errorMessage):
            ErrorContentView(message: errorMessage)

        case .images(let images):
            ImagesContentView(
                images: images,
                onPreview: { onTap?(.imagePreview($0)) }
            )

        case .attachments(let attachments):
            // Attachments-only message (no text) - show thumbnails
            AttachedFileThumbnails(
                attachments: attachments,
                onPreview: { onTap?(.imagePreview($0)) }
            )

        case .localNotification(let notification):
            LocalChatNotificationView(notification: notification) { detail in
                switch detail {
                case .error(let title, let message, let suggestion):
                    onTap?(.localErrorDetail(title: title, message: message, suggestion: suggestion))
                }
            }

        case .systemEvent(let event):
            SystemEventView(event: event, onTap: onTap)

        }
    }

}

enum ChatMessageLayout {
    /// The transcript stack contributes 12 points between ordinary rows.
    /// Provenance is a compact prelude to the resumed turn, so it uses an
    /// eight-point effective gap before the following thinking/tool/text row.
    static func bottomSpacingAdjustment(
        isDeliveryProvenanceOnly: Bool
    ) -> CGFloat {
        isDeliveryProvenanceOnly ? -4 : 0
    }
}

// MARK: - Confirmed Action Chip View

struct ConfirmedActionChipView: View {
    let approved: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(approved ? .tronSuccess : .tronError)

            Text(approved ? "Approved action" : "Denied action")
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronSurface.opacity(colorScheme == .light ? 0.85 : 0.6))
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Error Content View

private struct ErrorContentView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronError)

            Text(message)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronError)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.tronError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ScrollView {
        VStack(spacing: 12) {
            MessageBubble(message: .user("Hello, can you help me?"))
            MessageBubble(message: .assistant("Of course! I'd be happy to help."))

            // Test markdown table rendering
            MessageBubble(message: .assistant("""
            All tools working! Here's a summary:

            | Tool | Status | What it did |
            |------|--------|-------------|
            | ls | OK | Listed 8 files/folders |
            | read | OK | Read README.md |
            | edit | OK | Added a test comment |
            | grep | OK | Found 5 functions |
            | bash | OK | Ran echo command |

            Everything's working as expected!
            """))

            MessageBubble(message: .streaming("I'm currently typing..."))
            MessageBubble(message: .error("Something went wrong"))
        }
        .padding()
    }
    .background(Color.tronBackground)
}
#endif
