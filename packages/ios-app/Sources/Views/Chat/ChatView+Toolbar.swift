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
                if eventStoreManager.activeSession?.isFork == true {
                    Image(systemName: "arrow.triangle.branch")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11, height: 11)
                        .foregroundStyle(.tronPurple)
                        .offset(y: 1)
                        .transition(.opacity)
                }
                if let worktree = viewModel.worktreeState.worktree {
                    HStack(spacing: 2) {
                        Image("IconGit")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 15, height: 15)
                            .foregroundStyle(.tronCyan)
                        if worktree.hasUncommittedChanges == true {
                            Circle()
                                .fill(.orange)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .offset(y: 1)
                    .transition(.opacity)
                }
                TypewriterText(
                    text: eventStoreManager.activeSession?.displayTitle ?? "Chat",
                    font: TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold),
                    color: .tronEmerald
                )
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .animation(.smooth(duration: 0.25), value: eventStoreManager.activeSession?.isFork)
            .animation(.smooth(duration: 0.25), value: viewModel.worktreeState.worktree != nil)
        }
    }

    /// Trailing toolbar item (browser button and menu)
    @ToolbarContentBuilder
    var trailingToolbarItem: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Live stream button — visible only when a Display stream is active.
            if viewModel.isStreamActive {
                Button {
                    viewModel.showStreamSheet = true
                } label: {
                    Image(systemName: "play.rectangle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            }
            Menu {
                Button { NotificationCenter.default.post(name: .chatMenuAction, object: ChatMenuAction.history.rawValue) } label: {
                    Label("Session History", systemImage: "clock.arrow.circlepath")
                }
                Button { NotificationCenter.default.post(name: .chatMenuAction, object: ChatMenuAction.context.rawValue) } label: {
                    Label("Context Manager", systemImage: "gauge.with.dots.needle.67percent")
                }
                Button { NotificationCenter.default.post(name: .chatMenuAction, object: ChatMenuAction.changes.rawValue) } label: {
                    Label {
                        Text("Source Control")
                    } icon: {
                        Image("IconGit")
                            .renderingMode(.template)
                    }
                }
                if viewModel.processState.hasActiveProcesses {
                    Button { NotificationCenter.default.post(name: .chatMenuAction, object: ChatMenuAction.processes.rawValue) } label: {
                        Label("Processes (\(viewModel.processState.activeCount))", systemImage: "gearshape.arrow.triangle.2.circlepath")
                    }
                }
                Divider()
                Button { NotificationCenter.default.post(name: .chatMenuAction, object: ChatMenuAction.settings.rawValue) } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(.tronEmerald)
            }
        }
    }
}
