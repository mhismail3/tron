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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var inputHistory = InputHistoryStore()
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showContextAudit = false
    @State private var showSessionHistory = false
    @State private var showSessionAnalytics = false
    /// Cached models for model picker menu
    @State private var cachedModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    /// Optimistic model name for instant UI update
    @State private var optimisticModelName: String?
    /// Controls input field focus - set to false after response to prevent keyboard
    @State private var inputFocused = false

    // MARK: - Smart Auto-Scroll State
    /// Whether to auto-scroll to bottom on new content
    /// Set to false when user scrolls up, true when they tap button or send message
    @State private var autoScrollEnabled = true
    /// Track if there's new content while user is scrolled up
    @State private var hasUnreadContent = false
    /// Grace period after explicit user actions (button tap, send) to prevent gesture detection
    @State private var autoScrollGraceUntil: Date = .distantPast
    /// Track the last known bottom distance to detect when user scrolls back to bottom
    @State private var lastBottomDistance: CGFloat = 0

    private let sessionId: String
    private let rpcClient: RPCClient

    init(rpcClient: RPCClient, sessionId: String) {
        self.sessionId = sessionId
        self.rpcClient = rpcClient
        _viewModel = StateObject(wrappedValue: ChatViewModel(rpcClient: rpcClient, sessionId: sessionId))
    }

    /// Current model name (optimistic if pending, else actual)
    private var displayModelName: String {
        optimisticModelName ?? viewModel.currentModel
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

                    // Input area with integrated status pills and model picker
                    InputBar(
                        text: $viewModel.inputText,
                        isProcessing: viewModel.isProcessing,
                        isRecording: viewModel.isRecording,
                        isTranscribing: viewModel.isTranscribing,
                        attachedImages: $viewModel.attachedImages,
                        selectedImages: $viewModel.selectedImages,
                        onSend: {
                            inputHistory.addToHistory(viewModel.inputText)
                            // Reset auto-scroll when user sends a message
                            autoScrollEnabled = true
                            hasUnreadContent = false
                            // Grace period to prevent gesture detection during initial scroll animation
                            autoScrollGraceUntil = Date().addingTimeInterval(0.8)
                            viewModel.sendMessage()
                        },
                        onAbort: viewModel.abortAgent,
                        onMicTap: viewModel.toggleRecording,
                        onRemoveImage: viewModel.removeAttachedImage,
                        inputHistory: inputHistory,
                        onHistoryNavigate: { newText in
                            viewModel.inputText = newText
                        },
                        modelName: displayModelName,
                        tokenUsage: viewModel.totalTokenUsage,
                        contextPercentage: viewModel.contextPercentage,
                        cachedModels: cachedModels,
                        isLoadingModels: isLoadingModels,
                        onModelSelect: { model in
                            switchModel(to: model)
                        },
                        shouldFocus: $inputFocused
                    )
                    .id(sessionId)
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(eventStoreManager.activeSession?.displayTitle ?? "Chat")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                    if eventStoreManager.activeSession?.isFork == true {
                        Text("forked")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald.opacity(0.6))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                commandsMenu
            }
        }
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(rpcClient: rpcClient)
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
        .sheet(isPresented: $showSessionAnalytics) {
            SessionAnalyticsSheet(sessionId: sessionId)
                .environmentObject(eventStoreManager)
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        // Prevent keyboard from auto-opening after response completes
        .onChange(of: viewModel.isProcessing) { wasProcessing, isNowProcessing in
            if wasProcessing && !isNowProcessing {
                // Response just finished - dismiss keyboard
                inputFocused = false
            }
        }
        .task {
            // PERFORMANCE OPTIMIZATION: Parallelize independent operations
            // and ensure UI is responsive immediately
            //
            // Critical order:
            // 1. Set manager reference first (sync, instant)
            // 2. Pre-warm audio session for instant mic response
            // 3. Connect/resume and prefetch models run in parallel
            // 4. Sync/load messages runs after connect/resume completes
            //
            // Model prefetch and audio prewarm are independent and don't block UI

            let workspaceId = eventStoreManager.activeSession?.workspaceId ?? ""
            viewModel.setEventStoreManager(eventStoreManager, workspaceId: workspaceId)

            // Pre-warm audio session in background for instant mic button response
            // This eliminates the 100-300ms delay on first mic tap
            viewModel.prewarmAudioSession()

            // Run model prefetch in parallel with connect/resume
            // This is a fire-and-forget operation that doesn't block session entry
            Task {
                await prefetchModels()
            }

            // Connect and resume - this is required before loading messages
            await viewModel.connectAndResume()

            // Load messages after connection is established
            await viewModel.syncAndLoadMessagesForResume()
        }
    }

    /// Pre-fetch models for model picker menu
    private func prefetchModels() async {
        isLoadingModels = true
        if let models = try? await rpcClient.listModels() {
            cachedModels = models
            // Update context window from server-provided model info
            viewModel.updateContextWindow(from: models)
        }
        isLoadingModels = false
    }

    /// Switch model with optimistic UI update for instant feedback
    private func switchModel(to model: ModelInfo) {
        let previousModel = viewModel.currentModel

        // Optimistic update - UI updates instantly
        optimisticModelName = model.id
        // Update context window immediately with new model's value
        viewModel.currentContextWindow = model.contextWindow

        // Fire the actual switch in background
        Task {
            do {
                let result = try await rpcClient.switchModel(sessionId, model: model.id)
                await MainActor.run {
                    // Clear optimistic update - real value now in viewModel.currentModel
                    optimisticModelName = nil

                    // Add in-chat notification for model change
                    viewModel.addModelChangeNotification(
                        from: previousModel,
                        to: result.newModel
                    )
                    // Note: Model switch event is created by server and syncs automatically
                }
            } catch {
                await MainActor.run {
                    // Revert optimistic update on failure
                    optimisticModelName = nil
                    // Revert context window on failure
                    if let originalModel = cachedModels.first(where: { $0.id == previousModel }) {
                        viewModel.currentContextWindow = originalModel.contextWindow
                    }
                    viewModel.showErrorAlert("Failed to switch model: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Commands Menu

    private var commandsMenu: some View {
        Menu {
            // Model info (read-only, selection is via InputBar popup)
            Section {
                Label(displayModelName.shortModelName, systemImage: "cpu")
            }

            // Session section
            Section("Session") {
                Button {
                    showSessionAnalytics = true
                } label: {
                    Label("Analytics", systemImage: "chart.bar.xaxis")
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
                .foregroundStyle(.tronEmerald)
        }
        .menuIndicator(.hidden)
    }

    // Note: Status bar (model pill, token stats) is now integrated into InputBar
    // with iOS 26 liquid glass styling

    // MARK: - Messages Scroll View

    /// Distance to consider "at bottom" for re-enabling auto-scroll when processing ends
    private let atBottomThreshold: CGFloat = 50

    private var messagesScrollView: some View {
        GeometryReader { containerGeo in
            let containerHeight = containerGeo.size.height

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

                            // Scroll anchor with position detection for "at bottom" tracking
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: ScrollOffsetPreferenceKey.self,
                                        value: geo.frame(in: .named("scrollContainer")).minY - containerHeight
                                    )
                            }
                            .frame(height: 1)
                            .id("bottom")
                        }
                        .padding()
                    }
                    .coordinateSpace(name: "scrollContainer")
                    .scrollDismissesKeyboard(.interactively)
                    // GESTURE-BASED DETECTION: Detect user scrolling up via drag gesture
                    // When user drags finger down on screen, they're scrolling up through content
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 30)
                            .onChanged { value in
                                // Skip during grace period (after button tap or send message)
                                guard Date() > autoScrollGraceUntil else { return }

                                // User is dragging down (scrolling up through content)
                                // translation.height > 0 means finger moved down
                                if value.translation.height > 40 && autoScrollEnabled {
                                    logger.verbose("User scroll up detected - disabling auto-scroll", category: .ui)
                                    autoScrollEnabled = false
                                    if viewModel.isProcessing {
                                        hasUnreadContent = true
                                    }
                                }
                            }
                    )
                    // Track distance from bottom to re-enable auto-scroll when user scrolls back
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { distanceFromBottom in
                        lastBottomDistance = distanceFromBottom

                        // Re-enable auto-scroll ONLY when:
                        // 1. User has scrolled back to bottom (or very close)
                        // 2. NOT currently processing (to prevent snap-back during streaming)
                        // During processing, only the button can re-enable
                        if !viewModel.isProcessing && distanceFromBottom > -atBottomThreshold && !autoScrollEnabled {
                            logger.verbose("User scrolled to bottom - re-enabling auto-scroll", category: .ui)
                            autoScrollEnabled = true
                            hasUnreadContent = false
                        }
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
                        // Only auto-scroll during streaming if user hasn't scrolled up
                        if autoScrollEnabled {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        } else if viewModel.isProcessing {
                            // New content while scrolled up during processing
                            hasUnreadContent = true
                        }
                    }
                    .onChange(of: viewModel.isProcessing) { wasProcessing, isProcessing in
                        if wasProcessing && !isProcessing {
                            // Processing ended
                            if autoScrollEnabled {
                                // Was following - ensure at bottom
                                withAnimation(.tronFast) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                            // Clear unread content when processing ends
                            // (user will see the final state regardless of position)
                            hasUnreadContent = false
                        }
                    }
                }

                // Floating "New Messages" button - show when user has scrolled up during streaming
                if !autoScrollEnabled && hasUnreadContent {
                    scrollToBottomButton
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)).combined(with: .move(edge: .bottom)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                        .padding(.bottom, 16)
                        .animation(.tronStandard, value: hasUnreadContent)
                }
            }
        }
    }

    // MARK: - Scroll to Bottom Button

    private var scrollToBottomButton: some View {
        Button {
            // Re-enable auto-scroll first so the scroll animation isn't blocked
            autoScrollEnabled = true
            hasUnreadContent = false
            // Grace period to prevent gesture detection during scroll animation
            autoScrollGraceUntil = Date().addingTimeInterval(0.8)

            withAnimation(.tronStandard) {
                scrollProxy?.scrollTo("bottom", anchor: .bottom)
            }
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

// MARK: - Human-Readable Dates
extension CachedSession {
    // Cached formatters (creating these is expensive)
    // nonisolated(unsafe) because ISO8601DateFormatter is not Sendable, but we only read from them
    private static nonisolated(unsafe) let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static nonisolated(unsafe) let isoFormatterBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var humanReadableCreatedAt: String {
        // Parse ISO date and format nicely
        if let date = Self.isoFormatterWithFractional.date(from: createdAt) {
            return date.humanReadable
        }
        // Try without fractional seconds
        if let date = Self.isoFormatterBasic.date(from: createdAt) {
            return date.humanReadable
        }
        return createdAt
    }

    var humanReadableLastActivity: String {
        if let date = Self.isoFormatterWithFractional.date(from: lastActivityAt) {
            return date.humanReadable
        }
        if let date = Self.isoFormatterBasic.date(from: lastActivityAt) {
            return date.humanReadable
        }
        return formattedDate
    }
}

extension Date {
    // Cached formatters (creating these is expensive)
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    var humanReadable: String {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .hour, .day], from: self, to: now)

        if let days = components.day, days > 0 {
            if days == 1 { return "Yesterday" }
            if days < 7 {
                return Self.dayFormatter.string(from: self)
            }
            return Self.dateFormatter.string(from: self)
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
