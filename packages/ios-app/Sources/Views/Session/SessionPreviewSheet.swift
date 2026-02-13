import SwiftUI

// MARK: - Session Preview Sheet

/// Preview a session's history before forking. Shows read-only chat history with Fork/Back options.
@available(iOS 26.0, *)
struct SessionPreviewSheet: View {
    let session: SessionInfo
    let rpcClient: RPCClient
    let eventStoreManager: EventStoreManager
    let onFork: (String) -> Void
    let onDismiss: () -> Void

    @State private var events: [RawEvent] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var isForking = false
    @State private var forkError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.tronEmerald)
                        Text("Loading session history...")
                            .font(TronTypography.subheadline)
                            .foregroundStyle(.tronTextSecondary)
                    }
                } else if let error = loadError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                            .foregroundStyle(.tronError)
                        Text("Failed to load history")
                            .font(TronTypography.headline)
                            .foregroundStyle(.tronTextPrimary)
                        Text(error)
                            .font(TronTypography.subheadline)
                            .foregroundStyle(.tronTextSecondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadHistory() }
                        }
                        .foregroundStyle(.tronEmerald)
                    }
                    .padding()
                } else {
                    historyContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(session.displayName)
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                        Text("\(session.messageCount) messages")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isForking {
                        ProgressView()
                            .tint(.tronEmerald)
                    } else {
                        Button {
                            forkSession()
                        } label: {
                            Image(systemName: "arrow.branch")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronEmerald)
                        }
                    }
                }
            }
        }
        .task {
            await loadHistory()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - History Content

    private var historyContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                // Session info header
                sessionInfoHeader

                // Messages rendered with MessageBubble for visual parity with ChatView
                ForEach(displayMessages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var sessionInfoHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let dir = session.workingDirectory {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronEmerald.opacity(0.7))
                    Text(dir.replacingOccurrences(of: "/Users/[^/]+/", with: "~/", options: .regularExpression))
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    Text(session.model.shortModelName)
                        .font(TronTypography.codeCaption)
                }
                .foregroundStyle(.tronEmerald.opacity(0.8))

                Text(session.formattedDate)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                if session.isActive {
                    Text("ACTIVE")
                        .font(TronTypography.badge)
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronEmerald.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Display Messages

    /// Convert raw events to ChatMessage objects using the unified transformer.
    ///
    /// This uses UnifiedEventTransformer which provides 1:1 mapping with server events
    /// and ensures consistent rendering across all views (preview, chat, history).
    ///
    /// Key principle: Tool calls come from tool.call events, NOT from tool_use
    /// blocks embedded in message.assistant events. This eliminates duplication.
    private var displayMessages: [ChatMessage] {
        UnifiedEventTransformer.transformPersistedEvents(events)
    }

    // MARK: - Actions

    private func loadHistory() async {
        isLoading = true
        loadError = nil

        do {
            // Fetch ALL events from server (no type filter) to show complete history
            let result = try await rpcClient.eventSync.getHistory(
                sessionId: session.sessionId,
                types: nil,  // No filter - get everything
                limit: 1000
            )

            await MainActor.run {
                // Store raw events - UnifiedEventTransformer handles sorting and filtering
                events = result.events
                isLoading = false
                logger.debug("Loaded \(result.events.count) events for session \(session.sessionId.prefix(8))", category: .session)
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func forkSession() {
        guard !isForking else { return }

        isForking = true
        forkError = nil

        Task {
            do {
                let newSessionId = try await eventStoreManager.forkSession(session.sessionId, fromEventId: nil)

                await MainActor.run {
                    isForking = false
                    onFork(newSessionId)
                }
            } catch {
                await MainActor.run {
                    isForking = false
                    forkError = error.localizedDescription
                }
            }
        }
    }
}
