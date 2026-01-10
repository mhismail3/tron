import SwiftUI

// MARK: - Context Audit View

struct ContextAuditView: View {
    let rpcClient: RPCClient
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var detailedSnapshot: DetailedContextSnapshotResult?
    @State private var sessionEvents: [SessionEvent] = []
    @State private var isClearing = false
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.tronSurface.ignoresSafeArea()

                if isLoading {
                    ProgressView()
                        .tint(.tronEmerald)
                } else {
                    contentView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Context Manager")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Clear Context", isPresented: $showClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    Task { await clearContext() }
                }
            } message: {
                Text("This will remove all messages from context. System prompt and tools will be preserved. This cannot be undone.")
            }
            .task {
                await loadContext()
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Get session token usage from EventStoreManager
    private var sessionTokenUsage: (input: Int, output: Int, cacheRead: Int) {
        guard let session = eventStoreManager.sessions.first(where: { $0.id == sessionId }) else {
            return (0, 0, 0)
        }
        // Calculate cache tokens from events
        let cacheTokens = calculateCacheTokens()
        return (session.inputTokens, session.outputTokens, cacheTokens)
    }

    /// Calculate cache read tokens from session events
    private func calculateCacheTokens() -> Int {
        var total = 0
        for event in sessionEvents {
            if event.eventType == .messageAssistant || event.eventType == .streamTurnEnd {
                if let tokenUsage = event.payload["tokenUsage"]?.value as? [String: Any],
                   let cacheRead = tokenUsage["cacheReadTokens"] as? Int {
                    total += cacheRead
                }
            }
        }
        return total
    }

    private var contentView: some View {
        contextView
    }

    // MARK: - Context View

    private var contextView: some View {
        Group {
            if let snapshot = detailedSnapshot {
                ScrollView {
                    VStack(spacing: 16) {
                        // Usage gauge
                        ContextUsageGaugeView(
                            currentTokens: snapshot.currentTokens,
                            contextLimit: snapshot.contextLimit,
                            usagePercent: snapshot.usagePercent,
                            thresholdLevel: snapshot.thresholdLevel
                        )
                        .padding(.horizontal)

                        // Accumulated session tokens
                        TotalSessionTokensView(
                            inputTokens: sessionTokenUsage.input,
                            outputTokens: sessionTokenUsage.output,
                            cacheReadTokens: sessionTokenUsage.cacheRead
                        )
                        .padding(.horizontal)

                        // Token Breakdown header and expandable sections
                        TokenBreakdownHeader()
                            .padding(.horizontal)

                        // System Prompt + Tools (combined expandable section)
                        SystemAndToolsSection(
                            systemPromptTokens: snapshot.breakdown.systemPrompt,
                            toolsTokens: snapshot.breakdown.tools,
                            systemPromptContent: snapshot.systemPromptContent,
                            toolsContent: snapshot.toolsContent
                        )
                        .padding(.horizontal)

                        // Messages breakdown (granular expandable) - using server data
                        DetailedMessagesSection(messages: snapshot.messages)
                            .padding(.horizontal)

                        // Clear Context button
                        ClearContextButton(
                            isClearing: isClearing,
                            hasMessages: !snapshot.messages.isEmpty,
                            action: { showClearConfirmation = true }
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .padding(.vertical)
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.cyan)

                    Text("Loading context...")
                        .font(.caption)
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Data Loading

    private func loadContext() async {
        isLoading = true

        do {
            // Load detailed context snapshot and events in parallel
            async let snapshotTask = rpcClient.getDetailedContextSnapshot(sessionId: sessionId)
            let events = try eventStoreManager.getSessionEvents(sessionId)

            detailedSnapshot = try await snapshotTask
            sessionEvents = events
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func clearContext() async {
        isClearing = true

        do {
            _ = try await rpcClient.clearContext(sessionId: sessionId)
            // Reload context to show updated state
            await loadContext()
        } catch {
            errorMessage = "Failed to clear context: \(error.localizedDescription)"
        }

        isClearing = false
    }
}

// MARK: - Total Session Tokens View

struct TotalSessionTokensView: View {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int

    private var totalTokens: Int {
        inputTokens + outputTokens
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronEmerald)

                Text("Total Session Tokens")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Spacer()

                Text(formatTokenCount(totalTokens))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
            }

            // Token breakdown row
            HStack(spacing: 12) {
                // Input tokens
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.cyan)
                        Text("Input")
                            .font(.caption)
                            .foregroundStyle(.tronTextSecondary)
                    }
                    Text(formatTokenCount(inputTokens))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tronTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.cyan.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Output tokens
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tronEmerald)
                        Text("Output")
                            .font(.caption)
                            .foregroundStyle(.tronTextSecondary)
                    }
                    Text(formatTokenCount(outputTokens))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tronTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.tronEmerald.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Cache read tokens
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "memorychip.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.purple)
                        Text("Cached")
                            .font(.caption)
                            .foregroundStyle(.tronTextSecondary)
                    }
                    Text(formatTokenCount(cacheReadTokens))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tronTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.purple.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Footer explanation inside the container
            Text("Totals represent cumulative usage for this session")
                .font(.caption2)
                .foregroundStyle(.tronTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding()
        .background(Color.tronSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Context Usage Gauge View

struct ContextUsageGaugeView: View {
    let currentTokens: Int
    let contextLimit: Int
    let usagePercent: Double
    let thresholdLevel: String

    private var usageColor: Color {
        switch thresholdLevel {
        case "critical", "exceeded":
            return .red
        case "alert":
            return .orange
        case "warning":
            return .yellow
        default:
            return .cyan
        }
    }

    private var formattedTokens: String {
        formatTokenCount(currentTokens)
    }

    private var formattedLimit: String {
        formatTokenCount(contextLimit)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14))
                    .foregroundStyle(usageColor)

                Text("Context Usage")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Spacer()

                Text("\(Int(usagePercent * 100))%")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(usageColor)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.tronSurface)

                    // Fill
                    RoundedRectangle(cornerRadius: 6)
                        .fill(usageColor.opacity(0.8))
                        .frame(width: geometry.size.width * min(usagePercent, 1.0))
                }
            }
            .frame(height: 12)

            // Token counts
            HStack {
                Text("\(formattedTokens) / \(formattedLimit) tokens")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                Text("\(formatTokenCount(contextLimit - currentTokens)) remaining")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding()
        .background(Color.tronSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Token Breakdown Header

struct TokenBreakdownHeader: View {
    var body: some View {
        HStack {
            Image(systemName: "chart.pie")
                .font(.system(size: 14))
                .foregroundStyle(.cyan)

            Text("Token Breakdown")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tronTextPrimary)

            Spacer()
        }
        .padding(.top, 8)
    }
}

// MARK: - System and Tools Section

struct SystemAndToolsSection: View {
    let systemPromptTokens: Int
    let toolsTokens: Int
    let systemPromptContent: String
    let toolsContent: [String]

    @State private var isExpanded = false
    @State private var showingSystemPrompt = false
    @State private var showingTools = false

    private var totalTokens: Int {
        systemPromptTokens + toolsTokens
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (tappable)
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.purple)

                    Text("System Prompt & Tools")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tronTextPrimary)

                    Spacer()

                    Text(formatTokens(totalTokens))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tronTextSecondary)

                    Text("tokens")
                        .font(.caption2)
                        .foregroundStyle(.tronTextMuted)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
                .padding()
                .background(Color.tronSurfaceElevated)
            }
            .buttonStyle(.plain)

            // Expandable content
            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.tronBorder.opacity(0.3))

                    VStack(alignment: .leading, spacing: 8) {
                        // System Prompt - expandable
                        ExpandableContentSection(
                            icon: "doc.text.fill",
                            iconColor: .purple,
                            title: "System Prompt",
                            tokens: systemPromptTokens,
                            content: systemPromptContent,
                            isExpanded: $showingSystemPrompt
                        )

                        // Tools - expandable
                        ExpandableContentSection(
                            icon: "hammer.fill",
                            iconColor: .orange,
                            title: "Tools (\(toolsContent.count))",
                            tokens: toolsTokens,
                            content: toolsContent.joined(separator: "\n"),
                            isExpanded: $showingTools
                        )
                    }
                    .padding(12)
                }
                .background(Color.tronSurface.opacity(0.3))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.tronBorder.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Expandable Content Section

struct ExpandableContentSection: View {
    let icon: String
    let iconColor: Color
    let title: String
    let tokens: Int
    let content: String
    @Binding var isExpanded: Bool

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(iconColor.opacity(0.8))
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    Text(formatTokens(tokens))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tronTextMuted)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(10)
            }
            .buttonStyle(.plain)

            // Content
            if isExpanded {
                ScrollView {
                    Text(content)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tronTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .background(Color.tronBackground.opacity(0.5))
            }
        }
        .background(iconColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Detailed Messages Section (using server data)

struct DetailedMessagesSection: View {
    let messages: [DetailedMessageInfo]

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.cyan)

                Text("Messages")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tronTextPrimary)

                Text("(\(messages.count))")
                    .font(.caption)
                    .foregroundStyle(.tronTextMuted)

                Spacer()
            }
            .padding(.bottom, 4)

            if messages.isEmpty {
                Text("No messages in context")
                    .font(.caption)
                    .foregroundStyle(.tronTextMuted)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.tronSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.index) { index, message in
                        DetailedMessageRow(
                            message: message,
                            isLast: index == messages.count - 1
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.tronBorder.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Detailed Message Row

struct DetailedMessageRow: View {
    let message: DetailedMessageInfo
    let isLast: Bool

    @State private var isExpanded = false

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
        case "user": return .blue
        case "assistant": return .tronEmerald
        case "toolResult": return message.isError == true ? .red : .cyan
        default: return .gray
        }
    }

    private var title: String {
        switch message.role {
        case "user": return "User Message"
        case "assistant":
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                return toolCalls.map { $0.name }.joined(separator: ", ")
            }
            return "Assistant Response"
        case "toolResult": return message.isError == true ? "Tool Error" : "Tool Result"
        default: return "Message"
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (tappable)
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(iconColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tronTextPrimary)

                        if !isExpanded {
                            Text(message.summary)
                                .font(.caption2)
                                .foregroundStyle(.tronTextMuted)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Text(formatTokens(message.tokens))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.tronSurfaceElevated)
            }
            .buttonStyle(.plain)

            // Expandable content
            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.tronBorder.opacity(0.3))

                    // Show tool calls if present
                    if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(toolCalls) { toolCall in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "hammer.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.orange)
                                        Text(toolCall.name)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.tronTextPrimary)
                                        Spacer()
                                        Text(formatTokens(toolCall.tokens))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.tronTextMuted)
                                    }

                                    Text(toolCall.arguments)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tronTextSecondary)
                                        .lineLimit(5)
                                }
                                .padding(8)
                                .background(Color.orange.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(12)
                    }

                    // Show text content if present
                    if !message.content.isEmpty {
                        ScrollView {
                            Text(message.content)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tronTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                    }
                }
                .background(Color.tronSurface.opacity(0.3))
            }

            // Divider between items
            if !isLast {
                Divider()
                    .background(Color.tronBorder.opacity(0.15))
            }
        }
    }
}

// MARK: - Clear Context Button

struct ClearContextButton: View {
    let isClearing: Bool
    let hasMessages: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isClearing {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                }

                Text(isClearing ? "Clearing..." : "Clear Context")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(hasMessages ? Color.red.opacity(0.8) : Color.gray.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(isClearing || !hasMessages)
        .opacity(hasMessages ? 1.0 : 0.5)
    }
}

// MARK: - Preview

#Preview {
    ContextAuditView(
        rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!),
        sessionId: "test"
    )
}
