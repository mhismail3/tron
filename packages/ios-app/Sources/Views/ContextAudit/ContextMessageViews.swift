import SwiftUI

// MARK: - Detailed Message Row

@available(iOS 26.0, *)
struct DetailedMessageRow: View {
    let message: DetailedMessageInfo
    let isLast: Bool

    @State private var isExpanded = false
    @State private var contentExpanded = false

    private var icon: String {
        switch message.role {
        case "user": return "person.fill"
        case "assistant": return "sparkles"
        case "toolResult": return message.isError == true ? "xmark.circle.fill" : "checkmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch message.role {
        case "user": return .tronBlue
        case "assistant": return .tronEmerald
        case "toolResult": return message.isError == true ? .tronError : .tronCyan
        default: return .gray
        }
    }

    private var title: String {
        switch message.role {
        case "user": return "User"
        case "assistant":
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                let names = toolCalls.prefix(2).map { $0.name }
                let suffix = toolCalls.count > 2 ? " +\(toolCalls.count - 2)" : ""
                return names.joined(separator: ", ") + suffix
            }
            return "Assistant"
        case "toolResult": return message.isError == true ? "Error" : "Result"
        default: return "Message"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (tappable)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(iconColor)

                    // Summary fades out when expanded
                    Text(message.summary)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                        .opacity(isExpanded ? 0 : 1)
                        .frame(height: isExpanded ? 0 : nil, alignment: .top)
                        .clipped()
                }

                Spacer()

                Text(TokenFormatter.format(message.tokens))
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.top, 2)

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expandable content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Show tool calls if present
                    if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                        ForEach(toolCalls) { toolCall in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "hammer.fill")
                                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                        .foregroundStyle(.tronAmber)
                                    Text(toolCall.name)
                                        .font(TronTypography.codeCaption)
                                        .foregroundStyle(.tronAmber)
                                    Spacer()
                                    Text(TokenFormatter.format(toolCall.tokens))
                                        .font(TronTypography.pill)
                                        .foregroundStyle(.tronTextMuted)
                                }

                                Text(toolCall.arguments)
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextSecondary)
                                    .lineLimit(5)
                            }
                            .padding(8)
                            .sectionFill(.tronAmber, cornerRadius: 6)
                        }
                    }

                    // Show text content if present
                    if !message.content.isEmpty {
                        LineNumberedContentView(
                            content: message.content,
                            maxCollapsedLines: 12,
                            isExpanded: $contentExpanded,
                            fontSize: 10,
                            lineNumFontSize: 9,
                            maxCollapsedHeight: 200
                        )
                        .sectionFill(iconColor, cornerRadius: 6, subtle: true)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                            }
        }
        .sectionFill(iconColor, cornerRadius: 10)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Messages Container (Collapsible, matching Rules/Skills pattern)

@available(iOS 26.0, *)
struct MessagesContainer: View {
    let messages: [DetailedMessageInfo]
    let totalMessages: Int
    let totalTokens: Int
    let hasMoreMessages: Bool
    var onLoadMore: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (tappable)
            HStack(spacing: 8) {
                Image(systemName: "message.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                Text("Messages")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)

                // Count badge
                Text("\(totalMessages)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronEmerald)

                Spacer()

                Text(TokenFormatter.format(totalTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expandable content
            if isExpanded {
                VStack(spacing: 4) {
                    if totalMessages == 0 {
                        Text("No messages in context")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(messages) { message in
                                DetailedMessageRow(
                                    message: message,
                                    isLast: message.index == messages.last?.index
                                )
                            }

                            // Load more button
                            if hasMoreMessages {
                                Button {
                                    onLoadMore?()
                                } label: {
                                    HStack {
                                        Spacer()
                                        HStack(spacing: 6) {
                                            Image(systemName: "chevron.down")
                                                .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
                                            Text("Load \(min(10, totalMessages - messages.count)) more")
                                                .font(TronTypography.codeCaption)
                                        }
                                        .foregroundStyle(.tronEmerald)
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.tronEmerald.opacity(0.1))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronEmerald)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Added Skills Container (Collapsible, matching Rules/Skills pattern)

@available(iOS 26.0, *)
struct AddedSkillsContainer: View {
    let skills: [AddedSkillInfo]
    var onDelete: ((String) -> Void)?
    var onFetchContent: ((String) async -> String?)?

    @State private var isExpanded = false

    private var totalTokens: Int {
        let actual = skills.reduce(0) { $0 + ($1.tokens ?? 0) }
        return actual > 0 ? actual : skills.count * 200
    }

    private var isEstimate: Bool {
        !skills.contains { ($0.tokens ?? 0) > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronCyan)
                    .frame(width: 18)
                Text("Added Skills")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronCyan)

                // Count badge
                Text("\(skills.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronCyan)

                Spacer()

                Text("\(isEstimate ? "~" : "")\(TokenFormatter.format(totalTokens))")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                LazyVStack(spacing: 4) {
                    ForEach(skills) { skill in
                        AddedSkillRow(
                            skill: skill,
                            onDelete: { onDelete?(skill.name) },
                            onFetchContent: onFetchContent
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronCyan)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Analytics Section
