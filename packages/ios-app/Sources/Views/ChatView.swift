import SwiftUI
import PhotosUI

// MARK: - Scroll Position Tracking

/// Simple PreferenceKey to track scroll offset for detecting user scroll direction
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Chat View

@available(iOS 26.0, *)
struct ChatView: View {
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var inputHistory = InputHistoryStore()
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showModelSwitcher = false
    @State private var showSessionStats = false
    @State private var showContextAudit = false
    @State private var showSessionHistory = false
    /// Cached models for faster ModelSwitcher opening
    @State private var cachedModels: [ModelInfo] = []

    // MARK: - Smart Auto-Scroll State
    /// Auto-scroll is enabled when user is at/near the bottom of the chat
    /// Disabled when user scrolls up, re-enabled when they scroll back to bottom or tap the button
    @State private var autoScrollEnabled = true
    /// Track if there's new content while user is scrolled up
    @State private var hasUnreadContent = false
    /// Last scroll offset to detect scroll direction
    @State private var lastScrollOffset: CGFloat = 0

    private let sessionId: String
    private let rpcClient: RPCClient

    init(rpcClient: RPCClient, sessionId: String) {
        self.sessionId = sessionId
        self.rpcClient = rpcClient
        _viewModel = StateObject(wrappedValue: ChatViewModel(rpcClient: rpcClient, sessionId: sessionId))
    }

    var body: some View {
        // Main content with floating input bar using safeAreaInset
        messagesScrollView
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Floating input area - iOS 26 liquid glass, no backgrounds
                VStack(spacing: 8) {
                    // Thinking indicator
                    if !viewModel.thinkingText.isEmpty {
                        ThinkingBanner(
                            text: viewModel.thinkingText,
                            isExpanded: $viewModel.isThinkingExpanded
                        )
                    }

                    // Input area with integrated status pills
                    InputBar(
                        text: $viewModel.inputText,
                        isProcessing: viewModel.isProcessing,
                        attachedImages: $viewModel.attachedImages,
                        selectedImages: $viewModel.selectedImages,
                        onSend: {
                            inputHistory.addToHistory(viewModel.inputText)
                            // Reset auto-scroll when user sends a message - they're at the bottom
                            autoScrollEnabled = true
                            hasUnreadContent = false
                            viewModel.sendMessage()
                        },
                        onAbort: viewModel.abortAgent,
                        onRemoveImage: viewModel.removeAttachedImage,
                        inputHistory: inputHistory,
                        onHistoryNavigate: { newText in
                            viewModel.inputText = newText
                        },
                        modelName: viewModel.currentModel,
                        onModelTap: { showModelSwitcher = true },
                        tokenUsage: viewModel.totalTokenUsage,
                        contextPercentage: viewModel.contextPercentage
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle(eventStoreManager.activeSession?.displayTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                commandsMenu
            }
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showModelSwitcher) {
            ModelSwitcher(
                rpcClient: rpcClient,
                currentModel: viewModel.currentModel,
                sessionId: sessionId,
                onModelChanged: { newModel in
                    // Model changed - update cache
                },
                cachedModels: cachedModels.isEmpty ? nil : cachedModels
            )
        }
        .sheet(isPresented: $showSessionStats) {
            SessionStatsView(
                session: eventStoreManager.activeSession,
                tokenUsage: viewModel.totalTokenUsage
            )
        }
        .sheet(isPresented: $showContextAudit) {
            ContextAuditView(
                rpcClient: rpcClient,
                sessionId: sessionId
            )
        }
        .sheet(isPresented: $showSessionHistory) {
            SessionHistorySheet(
                sessionId: sessionId,
                rpcClient: rpcClient
            )
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .task {
            // Sync events from server to ensure local EventDatabase has latest state
            // This ensures tool calls and results are properly persisted
            do {
                try await eventStoreManager.syncSessionEvents(sessionId: sessionId)
            } catch {
                // Non-fatal: continue with local data if sync fails (offline mode)
                print("Event sync failed (using local cache): \(error.localizedDescription)")
            }

            // Inject event store manager for event-sourced persistence
            // This loads messages from EventDatabase (now synced with server)
            let workspaceId = eventStoreManager.activeSession?.workspaceId ?? ""
            viewModel.setEventStoreManager(eventStoreManager, workspaceId: workspaceId)
            await viewModel.connectAndResume()

            // Pre-fetch models in background for faster ModelSwitcher opening
            await prefetchModels()
        }
    }

    /// Pre-fetch models for faster ModelSwitcher opening
    private func prefetchModels() async {
        if let models = try? await rpcClient.listModels() {
            cachedModels = models
        }
    }

    // MARK: - Commands Menu

    private var commandsMenu: some View {
        Menu {
            // Model section
            Section {
                Button {
                    showModelSwitcher = true
                } label: {
                    Label(viewModel.currentModel.shortModelName, systemImage: "cpu")
                }
            }

            // Session section
            Section("Session") {
                Button {
                    showSessionStats = true
                } label: {
                    Label("Session Info", systemImage: "info.circle")
                }

                Button {
                    showSessionHistory = true
                } label: {
                    Label("Session History", systemImage: "arrow.triangle.branch")
                }

                Button {
                    showContextAudit = true
                } label: {
                    Label("Memory & Context", systemImage: "brain")
                }

                Button {
                    viewModel.clearMessages()
                } label: {
                    Label("Clear Messages", systemImage: "trash")
                }
            }

            // Settings section
            Section {
                Button {
                    viewModel.showSettings = true
                } label: {
                    Label("Settings", systemImage: TronIcon.settings.systemName)
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .menuIndicator(.hidden)
    }

    // Note: Status bar (model pill, token stats) is now integrated into InputBar
    // with iOS 26 liquid glass styling

    // MARK: - Messages Scroll View

    /// Threshold for disabling auto-scroll - if user scrolls this far from bottom, disable
    private let scrollUpDisableThreshold: CGFloat = 50
    /// Threshold for re-enabling - user must be very close to bottom (only used when NOT processing)
    private let nearBottomEnableThreshold: CGFloat = 30

    private var messagesScrollView: some View {
        GeometryReader { containerGeo in
            let containerFrame = containerGeo.frame(in: .global)

            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // Load more messages button (like iOS Messages)
                            if viewModel.hasMoreMessages {
                                loadMoreButton
                                    .id("loadMore")
                            }

                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                                        removal: .opacity
                                    ))
                            }

                            if viewModel.isProcessing && viewModel.messages.last?.isStreaming != true {
                                ProcessingIndicator()
                                    .id("processing")
                            }

                            // Scroll anchor with position detection
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: ScrollOffsetPreferenceKey.self,
                                        value: geo.frame(in: .global).minY
                                    )
                            }
                            .frame(height: 1)
                            .id("bottom")
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { bottomY in
                        // Calculate distance from bottom of viewport
                        // bottomY = global Y of bottom anchor
                        // containerFrame.maxY = bottom of visible scroll area
                        // Positive = scrolled up (anchor below viewport)
                        // Negative/zero = at bottom (anchor at or above viewport bottom)
                        let distanceFromBottom = bottomY - containerFrame.maxY

                        // Detect scroll direction from delta
                        let scrollDelta = bottomY - lastScrollOffset
                        let isUserScrollingUp = scrollDelta > 15

                        // DISABLE auto-scroll: User scrolled up past threshold during processing
                        if isUserScrollingUp && distanceFromBottom > scrollUpDisableThreshold {
                            if autoScrollEnabled {
                                autoScrollEnabled = false
                                hasUnreadContent = true
                            }
                        }

                        // RE-ENABLE auto-scroll: Only when NOT processing and user scrolled to very bottom
                        // During processing, only the button can re-enable (prevents snap-back)
                        if !viewModel.isProcessing && distanceFromBottom < nearBottomEnableThreshold && !autoScrollEnabled {
                            autoScrollEnabled = true
                            hasUnreadContent = false
                        }

                        lastScrollOffset = bottomY
                    }
                    .onAppear {
                        scrollProxy = proxy
                    }
                    .onChange(of: viewModel.messages.count) { oldCount, newCount in
                        if autoScrollEnabled {
                            withAnimation(.tronFast) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        } else if newCount > oldCount {
                            hasUnreadContent = true
                        }
                    }
                    .onChange(of: viewModel.messages.last?.content) { _, _ in
                        if autoScrollEnabled {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.isProcessing) { wasProcessing, isProcessing in
                        // When processing ends and auto-scroll is enabled, ensure we're at bottom
                        if wasProcessing && !isProcessing && autoScrollEnabled {
                            withAnimation(.tronFast) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                            hasUnreadContent = false
                        }
                    }
                }

                // Floating "scroll to bottom" button - show when auto-scroll disabled and unread content
                if !autoScrollEnabled && hasUnreadContent {
                    scrollToBottomButton
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Scroll to Bottom Button

    private var scrollToBottomButton: some View {
        Button {
            withAnimation(.tronStandard) {
                scrollProxy?.scrollTo("bottom", anchor: .bottom)
            }
            // Re-enable auto-scroll and clear unread indicator
            autoScrollEnabled = true
            hasUnreadContent = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                if hasUnreadContent {
                    Text("New content")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, hasUnreadContent ? 14 : 10)
            .padding(.vertical, 10)
            .background(.tronEmerald.opacity(0.9))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
    }

    // MARK: - Load More Button

    private var loadMoreButton: some View {
        Button {
            viewModel.loadMoreMessages()
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoadingMoreMessages {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white.opacity(0.7))
                } else {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 14, weight: .medium))
                }
                Text(viewModel.isLoadingMoreMessages ? "Loading..." : "Load Earlier Messages")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .disabled(viewModel.isLoadingMoreMessages)
        .padding(.bottom, 8)
    }
}

// MARK: - String Extension for Short Model Name

extension String {
    var shortModelName: String {
        let lowered = lowercased()

        // Detect tier
        let tier: String
        if lowered.contains("opus") {
            tier = "Opus"
        } else if lowered.contains("sonnet") {
            tier = "Sonnet"
        } else if lowered.contains("haiku") {
            tier = "Haiku"
        } else {
            let parts = split(separator: "-")
            if parts.count >= 2 {
                return String(parts[0]).capitalized + " " + String(parts[1]).capitalized
            }
            return self
        }

        // Detect version
        if lowered.contains("4-5") || lowered.contains("4.5") {
            return "\(tier) 4.5"
        }
        if lowered.contains("-4-") || lowered.contains("sonnet-4") || lowered.contains("opus-4") || lowered.contains("haiku-4") {
            return "\(tier) 4"
        }
        if lowered.contains("3-5") || lowered.contains("3.5") {
            return "\(tier) 3.5"
        }

        return tier
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            WaveformIcon(size: 16, color: .tronEmerald)
            Text("Processing...")
                .font(.caption)
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Thinking Banner

struct ThinkingBanner: View {
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.tronStandard) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    RotatingIcon(icon: .thinking, size: 12, color: .tronTextMuted)
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tronTextMuted)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .italic()
                    .lineLimit(10)
            }
        }
        .padding(10)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        )
        .padding(.horizontal)
    }
}

// MARK: - Session Stats View

struct SessionStatsView: View {
    let session: CachedSession?
    let tokenUsage: TokenUsage?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let session = session {
                    Section("Session") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ID")
                                .font(.subheadline)
                                .foregroundStyle(.tronTextSecondary)
                            Text(session.id)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tronTextPrimary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)

                        LabeledContent("Messages", value: "\(session.messageCount)")
                        LabeledContent("Created", value: session.humanReadableCreatedAt)
                        LabeledContent("Last Activity", value: session.humanReadableLastActivity)
                    }

                    Section("Workspace") {
                        Text(session.workingDirectory)
                            .font(.subheadline)
                            .foregroundStyle(.tronTextPrimary)
                    }

                    Section("Token Usage") {
                        LabeledContent("Input", value: formatTokenCount(session.inputTokens))
                        LabeledContent("Output", value: formatTokenCount(session.outputTokens))
                        LabeledContent("Total", value: formatTokenCount(session.inputTokens + session.outputTokens))
                    }
                }

                if let usage = tokenUsage {
                    Section("Current Request") {
                        LabeledContent("Input", value: formatTokenCount(usage.inputTokens))
                        LabeledContent("Output", value: formatTokenCount(usage.outputTokens))
                        LabeledContent("Total", value: formatTokenCount(usage.totalTokens))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
            .navigationTitle("Session Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// Extension for human-readable dates
extension CachedSession {
    var humanReadableCreatedAt: String {
        // Parse ISO date and format nicely
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: createdAt) {
            return date.humanReadable
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: createdAt) {
            return date.humanReadable
        }
        return createdAt
    }

    var humanReadableLastActivity: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: lastActivityAt) {
            return date.humanReadable
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: lastActivityAt) {
            return date.humanReadable
        }
        return formattedDate
    }
}

extension Date {
    var humanReadable: String {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .hour, .day], from: self, to: now)

        if let days = components.day, days > 0 {
            if days == 1 { return "Yesterday" }
            if days < 7 {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE"
                return formatter.string(from: self)
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: self)
        } else if let hours = components.hour, hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes) min ago"
        }
        return "Just now"
    }
}

// MARK: - Preview

// Note: Preview requires EventStoreManager which needs RPCClient and EventDatabase
// Previews can be enabled by creating mock instances
/*
#Preview {
    NavigationStack {
        ChatView(
            rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!),
            sessionId: "test-session"
        )
        .environmentObject(EventStoreManager(...))
    }
}
*/
