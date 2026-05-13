import SwiftUI

// MARK: - Message Bubble (Terminal-style matching web UI)

struct MessageBubble: View {
    let message: ChatMessage
    var onTap: ((MessageBubbleTapAction) -> Void)?

    private var isUserMessage: Bool {
        message.role == .user
    }

    /// Check if we have any metadata to display
    private var hasMetadata: Bool {
        message.tokenRecord != nil ||
        message.shortModelName != nil ||
        message.formattedLatency != nil
    }

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
            // Show attachments above skills for user messages (thumbnails at top)
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachedFileThumbnails(attachments: attachments)
            }

            // Show skills above text for user messages
            if let skills = message.skills, !skills.isEmpty {
                MessageSkillChips(skills: skills) { skill in
                    onTap?(.skill(skill))
                }
            }

            contentView

            // Show enriched metadata badge for assistant messages with metadata
            if !isUserMessage && hasMetadata {
                MessageMetadataBadge(
                    tokenRecord: message.tokenRecord,
                    model: message.shortModelName,
                    latency: message.formattedLatency
                )
            } else if let record = message.tokenRecord {
                // Fallback to simple token badge for user messages
                TokenBadge(record: record)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
        .accessibilityElement(children: isUserMessage ? .ignore : .contain)
        .accessibilityLabel(isUserMessage
            ? "You: \(String(message.content.textContent.prefix(200)))"
            : "Assistant message"
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .text(let text):
            TextContentView(text: text, role: message.role)

        case .streaming(let text):
            StreamingContentView(text: text)

        case .thinking(let visible, let isExpanded, let isStreaming):
            ThinkingContentView(content: visible, isExpanded: isExpanded, isStreaming: isStreaming) {
                onTap?(.thinking(visible))
            }

        case .capabilityInvocation(let invocation):
            CapabilityInvocationChip(
                data: invocation,
                onTap: { onTap?(.capabilityInvocation(invocation)) },
                onCancel: { onTap?(.cancelCapabilityInvocation(id: invocation.id)) }
            )

        case .capabilityResult(let result):
            CapabilityInvocationResultView(result: result)

        case .error(let errorMessage):
            ErrorContentView(message: errorMessage)

        case .images(let images):
            ImagesContentView(images: images)

        case .attachments(let attachments):
            // Attachments-only message (no text) - show thumbnails
            AttachedFileThumbnails(attachments: attachments)

        case .systemEvent(let event):
            SystemEventView(event: event, onTap: onTap)

        case .userInteraction(let data):
            UserInteractionCapabilityViewer(data: data) {
                onTap?(.userInteraction(data))
            }

        case .engineApproval(let data):
            EngineApprovalChipView(data: data) {
                onTap?(.engineApproval(data))
            }

        case .answeredQuestions(let count):
            AnsweredQuestionsChipView(questionCount: count)

        case .subagentResultsDelivered(let count):
            SubagentResultsDeliveredChipView(subagentCount: count)

        case .subagent(let data):
            SubagentChip(data: data) {
                onTap?(.subagent(data))
            }

        }
    }

}

// MARK: - Answered Questions Chip View

struct AnsweredQuestionsChipView: View {
    let questionCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronSuccess)

            Text("Answered agent's questions")
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

// MARK: - Subagent Results Delivered Chip View

struct SubagentResultsDeliveredChipView: View {
    let subagentCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronSuccess)

            Text(subagentCount == 1
                 ? "Sent sub-agent result"
                 : "Sent \(subagentCount) sub-agent results")
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
            All capabilities working! Here's a summary:

            | Capability | Status | What it did |
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
