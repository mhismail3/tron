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

    /// Principal toolbar item (title)
    @ToolbarContentBuilder
    var principalToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(eventStoreManager.activeSession?.displayTitle ?? "Chat")
                    .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                if eventStoreManager.activeSession?.isFork == true {
                    Text("forked")
                        .font(TronTypography.pillValue)
                        .foregroundStyle(.tronEmerald.opacity(0.6))
                }
            }
        }
    }

    /// Trailing toolbar item (browser button and menu)
    @ToolbarContentBuilder
    var trailingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                // Browser button - only visible when browser session is active
                if viewModel.hasBrowserSession {
                    Button {
                        viewModel.toggleBrowserWindow()
                    } label: {
                        Image(systemName: "globe")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }

                // iOS 26 fix: Use NotificationCenter to decouple button action from state mutation
                Menu {
                    Button { NotificationCenter.default.post(name: .chatMenuAction, object: "history") } label: {
                        Label("Session History", systemImage: "clock.arrow.circlepath")
                    }
                    Button { NotificationCenter.default.post(name: .chatMenuAction, object: "context") } label: {
                        Label("Context Manager", systemImage: "brain")
                    }
                    if viewModel.taskState.hasTasks {
                        Button { NotificationCenter.default.post(name: .chatMenuAction, object: "tasks") } label: {
                            Label("Tasks (\(viewModel.taskState.incompleteCount))", systemImage: "checklist")
                        }
                    }
                    Divider()
                    Button { NotificationCenter.default.post(name: .chatMenuAction, object: "settings") } label: {
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
}
