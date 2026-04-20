import SwiftUI

// MARK: - Toolbar Configuration

@available(iOS 26.0, *)
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
            }
        }
    }

    /// Principal toolbar item (title with optional fork + worktree icons)
    @ToolbarContentBuilder
    var principalToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(alignment: .center, spacing: 6) {
                SessionTitleIcons(
                    isFork: eventStoreManager.activeSession?.isFork == true,
                    worktree: viewModel.worktreeState.worktree
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
            .animation(
                .smooth(duration: 0.25),
                value: viewModel.worktreeState.worktree.map { !$0.isOnBaseBranch } ?? false
            )
        }
    }

    /// Trailing toolbar item (browser button and menu)
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
            Button {
                NotificationCenter.default.post(name: .chatMenuAction, object: ChatMenuAction.settings.rawValue)
            } label: {
                Image(systemName: "gearshape")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(.tronEmerald)
            }
        }
    }
}
