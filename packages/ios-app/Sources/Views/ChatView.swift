import SwiftUI
import PhotosUI

// MARK: - Chat View

struct ChatView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var inputHistory = InputHistoryStore()
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showModelSwitcher = false
    @State private var showSessionStats = false
    @State private var showHelp = false
    @State private var showContextAudit = false

    private let sessionId: String
    private let rpcClient: RPCClient

    init(rpcClient: RPCClient, sessionId: String) {
        self.sessionId = sessionId
        self.rpcClient = rpcClient
        _viewModel = StateObject(wrappedValue: ChatViewModel(rpcClient: rpcClient, sessionId: sessionId))
    }

    var body: some View {
        ZStack {
            // Background
            Color.tronBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Messages
                messagesScrollView

                // Thinking indicator
                if !viewModel.thinkingText.isEmpty {
                    ThinkingBanner(
                        text: viewModel.thinkingText,
                        isExpanded: $viewModel.isThinkingExpanded
                    )
                }

                // Status bar
                statusBar

                // Input area
                InputBar(
                    text: $viewModel.inputText,
                    isProcessing: viewModel.isProcessing,
                    attachedImages: $viewModel.attachedImages,
                    selectedImages: $viewModel.selectedImages,
                    onSend: {
                        // Add to history before sending
                        inputHistory.addToHistory(viewModel.inputText)
                        viewModel.sendMessage()
                        sessionStore.incrementMessageCount(for: sessionId)
                    },
                    onAbort: viewModel.abortAgent,
                    onRemoveImage: viewModel.removeAttachedImage,
                    inputHistory: inputHistory,
                    onHistoryNavigate: { newText in
                        viewModel.inputText = newText
                    }
                )
                .focused($isInputFocused)
            }
        }
        .navigationTitle(sessionStore.activeSession?.displayTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.tronSurface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                    // Model changed
                }
            )
        }
        .sheet(isPresented: $showSessionStats) {
            SessionStatsView(
                session: sessionStore.activeSession,
                tokenUsage: viewModel.totalTokenUsage
            )
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet()
        }
        .sheet(isPresented: $showContextAudit) {
            ContextAuditView(
                rpcClient: rpcClient,
                sessionId: sessionId
            )
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .task {
            // Inject session store for message persistence
            viewModel.setSessionStore(sessionStore)
            await viewModel.connectAndResume()
        }
        .onChange(of: viewModel.totalTokenUsage) { _, usage in
            if let usage = usage {
                sessionStore.updateTokenUsage(
                    for: sessionId,
                    input: usage.inputTokens,
                    output: usage.outputTokens
                )
            }
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
                    showHelp = true
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }

                Button {
                    viewModel.showSettings = true
                } label: {
                    Label("Settings", systemImage: TronIcon.settings.systemName)
                }
            }
        } label: {
            TronIconView(icon: .settings, size: 18)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            // Model badge
            Text(viewModel.currentModel.shortModelName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.tronSurfaceElevated)
                .clipShape(Capsule())

            Spacer()

            // Token usage
            if let usage = viewModel.totalTokenUsage {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9))
                        Text(usage.formattedInput)
                    }

                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9))
                        Text(usage.formattedOutput)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.tronSurface)
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
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

                    // Scroll anchor
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { scrollProxy = proxy }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(.tronFast) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
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
    let session: StoredSession?
    let tokenUsage: TokenUsage?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let session = session {
                    Section("Session") {
                        LabeledContent("ID", value: String(session.id.prefix(8)) + "...")
                        LabeledContent("Model", value: session.shortModel)
                        LabeledContent("Messages", value: "\(session.messageCount)")
                        LabeledContent("Created", value: session.createdAt.formatted())
                        LabeledContent("Last Activity", value: session.formattedDate)
                    }

                    Section("Workspace") {
                        Text(session.workingDirectory)
                            .font(.caption)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }

                if let usage = tokenUsage {
                    Section("Token Usage") {
                        LabeledContent("Input", value: usage.formattedInput)
                        LabeledContent("Output", value: usage.formattedOutput)
                        LabeledContent("Total", value: usage.formattedTotal)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
            .navigationTitle("Session Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Help Sheet

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Capabilities") {
                    FeatureHelpRow(icon: "folder", title: "File Access", description: "Read and write files in your workspace")
                    FeatureHelpRow(icon: "terminal", title: "Shell Commands", description: "Execute terminal commands")
                    FeatureHelpRow(icon: "pencil.and.outline", title: "Code Editing", description: "Make precise changes to your code")
                    FeatureHelpRow(icon: "photo", title: "Image Input", description: "Send images for analysis")
                }

                Section("Tips") {
                    Text("Use the menu to switch models, view session info, or access settings.")
                        .font(.subheadline)
                        .foregroundStyle(.tronTextSecondary)

                    Text("The status bar shows your connection state and token usage.")
                        .font(.subheadline)
                        .foregroundStyle(.tronTextSecondary)
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct FeatureHelpRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tronEmerald)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.tronTextPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ChatView(
            rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!),
            sessionId: "test-session"
        )
        .environmentObject(SessionStore())
    }
}
