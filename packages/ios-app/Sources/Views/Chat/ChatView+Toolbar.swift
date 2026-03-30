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

    /// Principal toolbar item (title + worktree badge)
    @ToolbarContentBuilder
    var principalToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    if eventStoreManager.activeSession?.isFork == true {
                        Image(systemName: "arrow.triangle.branch")
                            .font(TronTypography.caption2)
                            .foregroundStyle(.tronEmerald)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.tronEmerald.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(eventStoreManager.activeSession?.displayTitle ?? "Chat")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                if let worktree = viewModel.worktreeState.worktree {
                    WorktreeBadge(worktree: worktree)
                }
            }
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
