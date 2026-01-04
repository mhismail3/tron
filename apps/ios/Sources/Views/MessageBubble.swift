import SwiftUI

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            avatarView

            // Content
            VStack(alignment: .leading, spacing: 6) {
                contentView

                // Metadata row
                if let usage = message.tokenUsage {
                    TokenBadge(usage: usage)
                }
            }

            Spacer(minLength: 40)
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(avatarColor.opacity(0.2))
                .frame(width: 36, height: 36)

            avatarIcon
        }
    }

    private var avatarColor: Color {
        switch message.role {
        case .user: return .tronMint
        case .assistant: return .tronEmerald
        case .system: return .tronTextSecondary
        case .toolResult: return .tronInfo
        }
    }

    @ViewBuilder
    private var avatarIcon: some View {
        switch message.role {
        case .user:
            TronIconView(icon: .user, size: 18)
        case .assistant:
            if message.isStreaming {
                WaveformIcon(size: 18, color: .tronEmerald)
            } else {
                TronIconView(icon: .assistant, size: 18)
            }
        case .system:
            TronIconView(icon: .system, size: 18)
        case .toolResult:
            TronIconView(icon: .toolSuccess, size: 18)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .text(let text):
            TextContent(text: text, role: message.role)

        case .streaming(let text):
            StreamingContent(text: text)

        case .thinking(let visible, let isExpanded):
            ThinkingContent(content: visible, isExpanded: isExpanded)

        case .toolUse(let tool):
            ToolUseContent(tool: tool)

        case .toolResult(let result):
            ToolResultContent(result: result)

        case .error(let errorMessage):
            ErrorContent(message: errorMessage)

        case .images(let images):
            ImagesContent(images: images)
        }
    }
}

// MARK: - Text Content

struct TextContent: View {
    let text: String
    let role: MessageRole

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.body)
            .foregroundStyle(.tronTextPrimary)
            .textSelection(.enabled)
            .tronBubble(role: role)
    }
}

// MARK: - Streaming Content

struct StreamingContent: View {
    let text: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            if text.isEmpty {
                Text(" ")
                    .font(.body)
            } else {
                Text(LocalizedStringKey(text))
                    .font(.body)
                    .foregroundStyle(.tronTextPrimary)
            }

            StreamingCursor()
        }
        .tronBubble(role: .assistant)
    }
}

// MARK: - Thinking Content

struct ThinkingContent: View {
    let content: String
    let isExpanded: Bool

    @State private var expanded: Bool

    init(content: String, isExpanded: Bool) {
        self.content = content
        self.isExpanded = isExpanded
        self._expanded = State(initialValue: isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.tronStandard) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    TronIconView(icon: .thinking, size: 14)
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    TronIconView(
                        icon: expanded ? .collapse : .expand,
                        size: 10,
                        color: .tronTextMuted
                    )
                }
            }

            if expanded {
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.tronTextMuted)
                    .italic()
            }
        }
        .padding(12)
        .background(Color.tronPrimary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Tool Use Content

struct ToolUseContent: View {
    let tool: Models.ToolUseContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                statusIcon
                Text(tool.displayName)
                    .font(.subheadline.weight(.medium).monospaced())
                    .foregroundStyle(.tronTextPrimary)

                Spacer()

                if let duration = tool.formattedDuration {
                    Text(duration)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tronTextMuted)
                }
            }

            // Arguments preview
            if !tool.arguments.isEmpty {
                Text(tool.truncatedArguments)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(3)
            }

            // Result
            if let result = tool.result {
                Divider()
                    .background(Color.tronBorder)

                Text(result.prefix(300) + (result.count > 300 ? "..." : ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(5)
            }
        }
        .padding(12)
        .background(statusBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.status {
        case .running:
            RotatingIcon(icon: .toolRunning, size: 16, color: .tronInfo)
        case .success:
            TronIconView(icon: .toolSuccess, size: 16)
        case .error:
            TronIconView(icon: .toolError, size: 16)
        }
    }

    private var statusBackground: Color {
        switch tool.status {
        case .running: return .tronInfo.opacity(0.1)
        case .success: return .tronSuccess.opacity(0.1)
        case .error: return .tronError.opacity(0.1)
        }
    }

    private var statusBorder: Color {
        switch tool.status {
        case .running: return .tronInfo.opacity(0.3)
        case .success: return .tronSuccess.opacity(0.3)
        case .error: return .tronError.opacity(0.3)
        }
    }
}

// Namespace alias to avoid conflict with local struct
private typealias Models = TronMobile

// MARK: - Tool Result Content

struct ToolResultContent: View {
    let result: TronMobile.ToolResultContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TronIconView(
                    icon: result.isError ? .toolError : .toolSuccess,
                    size: 14
                )
                Text(result.isError ? "Error" : "Result")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(result.isError ? .tronError : .tronSuccess)
            }

            Text(result.truncatedContent)
                .font(.caption.monospaced())
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(12)
        .background(result.isError ? Color.errorBubble : Color.toolBubble)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Error Content

struct ErrorContent: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            TronIconView(icon: .error, size: 16)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tronError)
        }
        .padding(12)
        .background(Color.errorBubble)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronError.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Images Content

struct ImagesContent: View {
    let images: [ImageContent]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(images) { image in
                if let uiImage = UIImage(data: image.data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(8)
        .background(Color.userBubble)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Token Badge

struct TokenBadge: View {
    let usage: TokenUsage

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                Text(usage.formattedInput)
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                Text(usage.formattedOutput)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.tronTextMuted)
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 12) {
            MessageBubble(message: .user("Hello, can you help me?"))

            MessageBubble(message: .assistant("Of course! I'd be happy to help. What do you need?"))

            MessageBubble(message: .streaming("I'm currently typing this response"))

            MessageBubble(message: .error("Something went wrong"))
        }
        .padding()
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
