import SwiftUI
import PhotosUI

// MARK: - Chat View

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?

    init(rpcClient: RPCClient) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(rpcClient: rpcClient))
    }

    var body: some View {
        NavigationStack {
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

                    // Input area
                    InputBar(
                        text: $viewModel.inputText,
                        isProcessing: viewModel.isProcessing,
                        attachedImages: $viewModel.attachedImages,
                        selectedImages: $viewModel.selectedImages,
                        onSend: viewModel.sendMessage,
                        onAbort: viewModel.abortAgent,
                        onRemoveImage: viewModel.removeAttachedImage
                    )
                    .focused($isInputFocused)
                }
            }
            .navigationTitle("Tron")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionIndicator(state: viewModel.connectionState)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            viewModel.showSessionList = true
                        } label: {
                            Label("Sessions", systemImage: TronIcon.session.systemName)
                        }

                        Button {
                            viewModel.showSettings = true
                        } label: {
                            Label("Settings", systemImage: TronIcon.settings.systemName)
                        }
                    } label: {
                        TronIconView(icon: .settings, size: 18)
                    }
                }
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $viewModel.showSessionList) {
                SessionListView(viewModel: viewModel)
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await viewModel.connect()
            // Create initial session
            let documentsPath = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first?.path ?? "~"
            await viewModel.createNewSession(workingDirectory: documentsPath)
        }
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
                // Scroll when streaming content updates
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            WaveformIcon(size: 20, color: .tronEmerald)
            Text("Processing...")
                .font(.subheadline)
                .foregroundStyle(.tronTextSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Thinking Banner

struct ThinkingBanner: View {
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.tronStandard) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    RotatingIcon(icon: .thinking, size: 14, color: .tronPrimaryVivid)
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    TronIconView(
                        icon: isExpanded ? .collapse : .expand,
                        size: 12,
                        color: .tronTextMuted
                    )
                }
            }

            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.tronTextMuted)
                    .italic()
                    .lineLimit(10)
            }
        }
        .padding(12)
        .background(Color.tronPrimary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
    }
}

// MARK: - Preview

#Preview {
    ChatView(rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!))
}
