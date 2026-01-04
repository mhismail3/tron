import SwiftUI

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage

    private var isUserMessage: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUserMessage {
                Spacer(minLength: 60)
            } else {
                avatarView
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
                contentView

                if let usage = message.tokenUsage {
                    TokenBadge(usage: usage)
                }
            }

            if isUserMessage {
                // No avatar for user - cleaner look
            } else {
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(avatarColor)
                .frame(width: 28, height: 28)

            avatarIcon
        }
    }

    private var avatarColor: Color {
        switch message.role {
        case .user: return .tronEmerald
        case .assistant: return .tronSurfaceElevated
        case .system: return .tronSurface
        case .toolResult: return .tronInfo.opacity(0.2)
        }
    }

    @ViewBuilder
    private var avatarIcon: some View {
        switch message.role {
        case .user:
            TronIconView(icon: .user, size: 14, color: .white)
        case .assistant:
            if message.isStreaming {
                WaveformIcon(size: 14, color: .tronEmerald)
            } else {
                TronIconView(icon: .assistant, size: 14, color: .tronEmerald)
            }
        case .system:
            TronIconView(icon: .system, size: 14, color: .tronTextMuted)
        case .toolResult:
            TronIconView(icon: .toolSuccess, size: 14)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .text(let text):
            TextContentView(text: text, role: message.role)

        case .streaming(let text):
            StreamingContentView(text: text)

        case .thinking(let visible, let isExpanded):
            ThinkingContentView(content: visible, isExpanded: isExpanded)

        case .toolUse(let tool):
            ToolUseView(tool: tool)

        case .toolResult(let result):
            ToolResultView(result: result)

        case .error(let errorMessage):
            ErrorContentView(message: errorMessage)

        case .images(let images):
            ImagesContentView(images: images)
        }
    }
}

// MARK: - Text Content View

struct TextContentView: View {
    let text: String
    let role: MessageRole

    private var isUser: Bool { role == .user }

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.body)
            .foregroundStyle(isUser ? .white : .tronTextPrimary)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var bubbleBackground: Color {
        switch role {
        case .user: return .tronEmerald
        case .assistant: return .tronSurfaceElevated
        case .system: return .tronSurface
        case .toolResult: return .toolBubble
        }
    }
}

// MARK: - Streaming Content View

struct StreamingContentView: View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.tronSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Thinking Content View

struct ThinkingContentView: View {
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
                    TronIconView(icon: .thinking, size: 12, color: .tronTextMuted)
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tronTextMuted)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            if expanded {
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .italic()
            }
        }
        .padding(10)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Tool Use View

struct ToolUseView: View {
    let tool: ToolUseData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusIcon
                Text(tool.displayName)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                Spacer()

                if let duration = tool.formattedDuration {
                    Text(duration)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tronTextMuted)
                }
            }

            if !tool.arguments.isEmpty {
                Text(tool.truncatedArguments)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(2)
            }

            if let result = tool.result {
                Divider()
                    .background(Color.tronBorder)

                Text(result.prefix(200) + (result.count > 200 ? "..." : ""))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(4)
            }
        }
        .padding(10)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(statusBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.status {
        case .running:
            RotatingIcon(icon: .toolRunning, size: 12, color: .tronInfo)
        case .success:
            TronIconView(icon: .toolSuccess, size: 12, color: .tronSuccess)
        case .error:
            TronIconView(icon: .toolError, size: 12, color: .tronError)
        }
    }

    private var statusBorder: Color {
        switch tool.status {
        case .running: return .tronInfo.opacity(0.4)
        case .success: return .tronBorder
        case .error: return .tronError.opacity(0.4)
        }
    }
}

// MARK: - Tool Result View

struct ToolResultView: View {
    let result: ToolResultData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TronIconView(
                    icon: result.isError ? .toolError : .toolSuccess,
                    size: 12,
                    color: result.isError ? .tronError : .tronSuccess
                )
                Text(result.isError ? "Error" : "Result")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(result.isError ? .tronError : .tronTextMuted)
            }

            Text(result.truncatedContent)
                .font(.caption2.monospaced())
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(4)
        }
        .padding(10)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(result.isError ? Color.tronError.opacity(0.3) : Color.tronBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Error Content View

struct ErrorContentView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            TronIconView(icon: .error, size: 14, color: .tronError)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(10)
        .background(Color.tronError.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.tronError.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Images Content View

struct ImagesContentView: View {
    let images: [ImageContent]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(images) { image in
                if let uiImage = UIImage(data: image.data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(4)
        .background(Color.tronEmerald.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            MessageBubble(message: .assistant("Of course! I'd be happy to help."))
            MessageBubble(message: .streaming("I'm currently typing..."))
            MessageBubble(message: .error("Something went wrong"))
        }
        .padding()
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
