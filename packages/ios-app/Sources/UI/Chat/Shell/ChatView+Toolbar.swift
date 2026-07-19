import SwiftUI

// MARK: - Toolbar Configuration

extension ChatView {
    /// Leading toolbar item (back button or sidebar toggle)
    @ToolbarContentBuilder
    var leadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let onToggleSidebar = onToggleSidebar {
                // iPad - show sidebar toggle
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.leading")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            } else {
                // iPhone - show back button
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                .accessibilityLabel("Back")
            }
        }
    }

    /// Principal toolbar item (title with optional fork icon)
    @ToolbarContentBuilder
    var principalToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(alignment: .center, spacing: 6) {
                SessionTitleIcons(
                    isFork: eventStoreManager.activeSession?.isFork == true
                )
                TypewriterText(
                    text: eventStoreManager.activeSession?.displayTitle ?? "Chat",
                    font: TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold),
                    color: .tronEmerald
                )
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .opacity(toolbarTitleOpacity)
            .offset(y: toolbarTitleOffsetY)
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeOut(duration: 0.4)) {
                    toolbarTitleOpacity = 1
                    toolbarTitleOffsetY = 0
                }
            }
            .animation(.smooth(duration: 0.25), value: eventStoreManager.activeSession?.isFork)
        }
    }

    /// Trailing toolbar item (live stream and first-class session workflows)
    @ToolbarContentBuilder
    var trailingToolbarItem: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Live stream button — visible only when a Display stream is active.
            if viewModel.displayStreamState.isStreamActive {
                Button {
                    viewModel.displayStreamState.showStreamSheet = true
                } label: {
                    Image(systemName: "play.rectangle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            }
            Menu {
                Button {
                    NotificationCenter.default.post(
                        name: .chatMenuAction,
                        object: ChatMenuRequest(action: .branch, sessionId: sessionId)
                    )
                } label: {
                    Label("Branch session", systemImage: "arrow.triangle.branch")
                }
                .disabled(!BranchSessionMutationPolicy.canBranch(
                    isConnected: interactionPolicy?.isConnected ?? false,
                    isProcessing: viewModel.isProcessing,
                    isCreatingBranch: isCreatingBranch
                ))

                Button {
                    NotificationCenter.default.post(
                        name: .chatMenuAction,
                        object: ChatMenuRequest(action: .settings, sessionId: sessionId)
                    )
                } label: {
                    Label("Chat settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: isCreatingBranch ? "circle.dotted" : "ellipsis.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(.tronEmerald)
            }
            .accessibilityLabel("Session actions")
        }
    }

    @MainActor
    func createBranch() {
        guard BranchSessionMutationPolicy.canBranch(
            isConnected: interactionPolicy?.isConnected ?? false,
            isProcessing: viewModel.isProcessing,
            isCreatingBranch: isCreatingBranch
        ) else { return }

        isCreatingBranch = true
        Task {
            defer { isCreatingBranch = false }
            do {
                let newSessionId = try await eventStoreManager.forkSession(sessionId)
                NotificationCenter.default.post(name: .switchToSession, object: newSessionId)
            } catch {
                sheetCoordinator.showLocalErrorDetail(
                    title: "Branch could not be created",
                    message: error.localizedDescription,
                    suggestion: "Wait for the current response to finish, then try again."
                )
            }
        }
    }
}

enum BranchSessionMutationPolicy {
    static func canBranch(
        isConnected: Bool,
        isProcessing: Bool,
        isCreatingBranch: Bool
    ) -> Bool {
        isConnected && !isProcessing && !isCreatingBranch
    }
}
